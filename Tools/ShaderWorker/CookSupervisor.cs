using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal sealed record CookPlan(string ProjectRoot, string RunFolder, string Uat, string[] Arguments, string AutomationFolder, int Attempt = 1, int StallSeconds = 900);
internal sealed record CookQueueSnapshot(string CookToken, DateTime UpdatedUtc, int ProcessId, int OutstandingJobs, int QueuedJobs, bool Running);

internal sealed class CookSupervisor
{
    internal const int StalledExitCode = 86;
    private readonly Dictionary<string, long> offsets = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, (string Signature, long Since)> pending = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> shaderRoots = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> workers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<(string File, int Batch), int> batchJobs = new();
    private readonly object stateLock = new();
    private long completed;
    private long completedJobs;
    private long batchesWithUnknownJobCount;
    private readonly Stopwatch elapsed = Stopwatch.StartNew();
    private readonly Dictionary<int, CookQueueSnapshot> queues = new();
    private string token = "";
    private bool packaging;
    private int expectedWorkers;
    private string? reason;
    private string? detail;
    private string project = "";
    private string tempShaders = "";

    private static bool Under(string path, string root) => Path.GetFullPath(path).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    private void AddShaderRoot(string path)
    {
        var full = Path.GetFullPath(path);
        if (Under(full, Path.Combine(project, "Intermediate")) || Under(full, tempShaders)) shaderRoots.Add(full);
    }

    private void ObserveEngineLine(string line)
    {
        lock (stateLock)
        {
            var count = Regex.Match(line, @"Using (\d+) local workers for shader compilation");
            if (count.Success) expectedWorkers = int.Parse(count.Groups[1].Value);
            var root = Regex.Match(line, @"Cleaned the shader compiler working directory '([^']+)'");
            if (root.Success) AddShaderRoot(root.Groups[1].Value);
            var phase = Regex.Match(line, @"\*+ (STAGE|PACKAGE|ARCHIVE) COMMAND STARTED");
            if (phase.Success)
            {
                packaging = true;
                var label = phase.Groups[1].Value switch { "STAGE" => "Staging packaged files...", "PACKAGE" => "Packaging mod...", _ => "Archiving packaged files..." };
                Console.WriteLine("LIMELIGHT_STATUS " + label);
            }
            if (line.Contains("No shader compile worker state change in", StringComparison.Ordinal))
                Console.WriteLine("LIMELIGHT_STATUS Shader workers have stopped reporting progress. Checking pending batches...");
            if (line.Contains("Falling back to directly compiling", StringComparison.OrdinalIgnoreCase))
            {
                reason ??= "WorkerExitedWithoutOutput";
                detail ??= "Unreal reported a worker exiting without its result. The uncorrected inline-compiler fallback was stopped.";
            }
        }
    }

    private static IEnumerable<string> Tail(string path, Dictionary<string, long> cursors)
    {
        byte[] bytes;
        long offset = cursors.GetValueOrDefault(path);
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length < offset) offset = 0;
            stream.Position = offset;
            bytes = new byte[(int)Math.Min(stream.Length - offset, 4 * 1024 * 1024)];
            int read = stream.Read(bytes);
            if (read == 0) return Array.Empty<string>();
            int last = Array.LastIndexOf(bytes, (byte)'\n', read - 1, read);
            if (last < 0) return Array.Empty<string>();
            cursors[path] = offset + last + 1;
            return Encoding.UTF8.GetString(bytes, 0, last + 1).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        }
        catch (IOException) { return Array.Empty<string>(); }
    }

    private void ReadProgress(string automation)
    {
        var progress = Path.Combine(project, "Saved", "ShaderAdapter", "Progress");
        if (token.Length > 0 && Directory.Exists(progress))
            foreach (var file in Directory.EnumerateFiles(progress, "Queue-*.json"))
                try
                {
                    var snapshot = JsonSerializer.Deserialize<CookQueueSnapshot>(File.ReadAllText(file));
                    if (snapshot != null && snapshot.CookToken == token && snapshot.ProcessId > 0
                        && snapshot.OutstandingJobs >= 0 && snapshot.QueuedJobs >= 0) queues[snapshot.ProcessId] = snapshot;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        if (Directory.Exists(automation))
            foreach (var file in Directory.EnumerateFiles(automation, "Cook-*.txt"))
                foreach (var line in Tail(file, offsets)) ObserveEngineLine(line);
        var logs = Path.Combine(project, "Saved", "ShaderAdapter", "Logs");
        if (!Directory.Exists(logs)) return;
        foreach (var file in Directory.EnumerateFiles(logs, "worker-*.jsonl"))
            foreach (var line in Tail(file, offsets))
            {
                using var record = JsonDocument.Parse(line);
                var data = record.RootElement.GetProperty("detail");
                var action = data.GetProperty("action").GetString();
                if (action is "boot" or "start")
                {
                    var working = data.GetProperty("working").GetString()!;
                    AddShaderRoot(Path.GetDirectoryName(working)!);
                    workers.Add(working);
                }
                if (action == "adapted" && data.TryGetProperty("report", out var report) && report.TryGetProperty("jobs", out var jobs))
                    batchJobs[(file, data.GetProperty("batch").GetInt32())] = jobs.GetInt32();
                if (action == "completed")
                {
                    completed++;
                    int batch = data.GetProperty("batch").GetInt32();
                    bool known = batchJobs.Remove((file, batch), out int count);
                    if (data.TryGetProperty("jobs", out var jobsDone)) { count = jobsDone.GetInt32(); known = true; }
                    if (known && count >= 0) completedJobs += count;
                    else batchesWithUnknownJobCount++;
                }
                if (action == "fatal")
                {
                    bool timedOut = data.TryGetProperty("timedOut", out var timeout) && timeout.GetBoolean();
                    reason ??= timedOut ? "ShaderWorkersStalled" : "WorkerReportedFailure";
                    detail ??= data.GetProperty("error").GetString();
                }
            }
    }

    private void CheckPending(int timeoutSeconds)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in shaderRoots.Where(Directory.Exists).ToArray())
        {
            if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) continue;
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                if (!int.TryParse(Path.GetFileName(directory), out _) || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) continue;
                var input = Path.Combine(directory, "WorkerInputOnly.in");
                if (!File.Exists(input) || File.Exists(Path.Combine(directory, "WorkerOutputOnly.out"))) continue;
                string signature;
                try { var info = new FileInfo(input); signature = info.Length + ":" + info.LastWriteTimeUtc.Ticks; }
                catch (IOException) { continue; }
                seen.Add(input);
                if (!pending.TryGetValue(input, out var old) || old.Signature != signature)
                    pending[input] = (signature, Environment.TickCount64);
                else if (Environment.TickCount64 - old.Since >= timeoutSeconds * 1000L)
                {
                    reason ??= "ShaderWorkersStalled";
                    detail ??= $"A shader batch produced no result for {timeoutSeconds} seconds: {input}";
                }
            }
        }
        foreach (var key in pending.Keys.Where(p => !seen.Contains(p)).ToArray()) pending.Remove(key);
    }

    private void Save(string path, int? exitCode, bool stopped)
    {
        var current = queues.Values.Where(QueueIsFresh).ToArray();
        var report = new { UpdatedUtc = DateTime.UtcNow, Reason = reason, Detail = detail, ExitCode = exitCode,
            StoppedOwnedProcessTree = stopped, CompletedBatches = completed, ExpectedWorkers = expectedWorkers,
            CompletedWorkerJobs = completedJobs, CompletedBatchesWithUnknownJobCount = batchesWithUnknownJobCount,
            EngineOutstandingJobs = current.Length > 0 ? current.Sum(s => (long)s.OutstandingJobs) : (long?)null,
            EngineQueuedJobs = current.Length > 0 ? current.Sum(s => (long)s.QueuedJobs) : (long?)null,
            EngineQueueProcessCount = current.Length,
            QueueCountUpdatedUtc = queues.Values.Select(s => (DateTime?)s.UpdatedUtc).Max(), QueueCountAvailable = current.Length > 0,
            ElapsedSeconds = elapsed.Elapsed.TotalSeconds,
            WorkersReportedStartup = workers.Count, PendingInputs = pending.Keys.ToArray() };
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, overwrite: true);
    }

    private static bool QueueIsFresh(CookQueueSnapshot snapshot)
    {
        var age = DateTime.UtcNow - snapshot.UpdatedUtc;
        return age >= TimeSpan.FromSeconds(-5) && age <= TimeSpan.FromSeconds(10);
    }

    private string ProgressStatus()
    {
        string Count(long value) => value.ToString("N0", CultureInfo.InvariantCulture);
        var jobs = batchesWithUnknownJobCount == 0 ? $"{Count(completedJobs)} worker jobs completed; " : "";
        var current = queues.Values.Where(QueueIsFresh).ToArray();
        var remaining = current.Length > 0 ? $"{Count(current.Sum(s => (long)s.OutstandingJobs))} engine jobs remaining now (queued/running)" : "remaining count not yet available";
        var time = $"{(int)elapsed.Elapsed.TotalHours}:{elapsed.Elapsed.Minutes:00}:{elapsed.Elapsed.Seconds:00}";
        return $"LIMELIGHT_STATUS Compiling shaders: {jobs}{remaining}. Batches: {Count(completed)} completed; {pending.Count} active. Workers started: {workers.Count}/{expectedWorkers}. Elapsed {time}.";
    }

    public static async Task<int> Run(string planPath)
    {
        var plan = JsonSerializer.Deserialize<CookPlan>(File.ReadAllText(planPath)) ?? throw new IOException("Missing cook monitor plan.");
        if (plan.StallSeconds is < 1 or > 7200 || plan.Attempt is < 1 or > 2) throw new IOException("Invalid cook monitor limits.");
        var monitor = new CookSupervisor { project = Path.GetFullPath(plan.ProjectRoot), tempShaders = Path.Combine(Path.GetTempPath(), "UnrealShaderWorkingDir"), token = Environment.GetEnvironmentVariable("LIMELIGHT_SHADER_COOK_TOKEN") ?? "" };
        var reportPath = Path.Combine(plan.RunFolder, $"CookMonitor-attempt-{plan.Attempt}.json");
        var helper = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Run-Uat.ps1"));
        var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(shell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper, "-Plan", Path.GetFullPath(planPath) }) start.ArgumentList.Add(argument);
        using var child = Process.Start(start) ?? throw new IOException("Could not start the owned UAT launcher.");
        async Task Pump(StreamReader reader)
        {
            while (await reader.ReadLineAsync() is { } line)
            {
                Console.WriteLine(line);
                monitor.ObserveEngineLine(line);
            }
        }
        var output = Task.WhenAll(Pump(child.StandardOutput), Pump(child.StandardError));
        bool stopped = false;
        try
        {
            long nextStatus = Environment.TickCount64;
            long publishedCompleted = -1;
            while (!child.HasExited)
            {
                lock (monitor.stateLock)
                {
                    monitor.ReadProgress(plan.AutomationFolder);
                    monitor.CheckPending(plan.StallSeconds);
                    if (monitor.reason != null) break;
                    if (Environment.TickCount64 >= nextStatus)
                    {
                        monitor.Save(reportPath, null, false);
                        if (!monitor.packaging && (monitor.pending.Count > 0 || monitor.queues.Values.Any(QueueIsFresh) || (monitor.completed > 0 && monitor.completed != publishedCompleted)))
                            Console.WriteLine(monitor.ProgressStatus());
                        publishedCompleted = monitor.completed;
                        nextStatus = Environment.TickCount64 + 5000;
                    }
                }
                await Task.Delay(500);
            }
            if (monitor.reason != null && !child.HasExited)
            {
                child.Kill(entireProcessTree: true);
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
                stopped = true;
            }
            await output.WaitAsync(TimeSpan.FromSeconds(15));
            lock (monitor.stateLock)
            {
                monitor.ReadProgress(plan.AutomationFolder);
                monitor.Save(reportPath, child.ExitCode, stopped);
                if (monitor.reason != null)
                {
                    var capture = Path.Combine(plan.RunFolder, $"ShaderStallInputs-attempt-{plan.Attempt}");
                    long captured = 0;
                    foreach (var input in monitor.pending.Keys)
                    {
                        try
                        {
                            var info = new FileInfo(input);
                            if (!info.Exists || info.Length > 64 * 1024 * 1024 || captured + info.Length > 128 * 1024 * 1024 || (info.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                            Directory.CreateDirectory(capture);
                            File.Copy(input, Path.Combine(capture, Path.GetFileName(Path.GetDirectoryName(input)) + ".in"));
                            captured += info.Length;
                        }
                        catch (IOException) { }
                    }
                }
            }
            return monitor.reason != null ? StalledExitCode : child.ExitCode;
        }
        catch
        {
            if (!child.HasExited) { child.Kill(entireProcessTree: true); await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15)); }
            throw;
        }
    }
}
