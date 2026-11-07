using System.Diagnostics;
using System.Text.Json;

internal sealed record AdapterSettings(string ProjectRoot, string ProjectFile, string Python, string AdapterScript, string AdapterScriptSha256, string NativeWorker, string NativeWorkerSha256, string CookToken, bool KeepShaderDebug = false);

internal static class Program
{
    private static string logPath = "";
    private static string? taskInput;
    private static string? taskOutput;
    private static void Record(object value) => File.AppendAllText(logPath, JsonSerializer.Serialize(new { utc = DateTime.UtcNow, detail = value }) + Environment.NewLine);
    private static string Canonical(string path) => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
    private static bool Under(string path, string root) => Canonical(path).StartsWith(Canonical(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    private static async Task ReportFailure(Exception error)
    {
        if (taskInput is null || taskOutput is null) return;
        var message = System.Text.Encoding.Unicode.GetBytes("Limelight Shader Cooker: " + error.Message);
        using var data = new MemoryStream();
        using (var writer = new BinaryWriter(data, System.Text.Encoding.Unicode, leaveOpen: true))
        {
            // I use the engine's version-28 crash header so the cook can report a failed task.
            writer.Write(28); writer.Write((long)(60 + message.Length));
            writer.Write(1); writer.Write(0.0); writer.Write(0.0); writer.Write(0.0); writer.Write(0);
            writer.Write(0); writer.Write(0); writer.Write(message.Length / 2); writer.Write(0);
            writer.Write(message);
        }
        var temporary = taskOutput + ".failure-" + Environment.ProcessId;
        await File.WriteAllBytesAsync(temporary, data.ToArray());
        File.Move(temporary, taskOutput, overwrite: true);
        File.Delete(taskInput);
    }

    private static async Task<int> Run(string executable, IEnumerable<string> arguments, string directory, string stdoutPath, string stderrPath)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        Record(new { action = "launching-child", executable, directory });
        using var child = Process.Start(start) ?? throw new IOException("Could not start the shader adapter child process.");
        Record(new { action = "child-started", executable, childId = child.Id });
        using var stdoutFile = new FileStream(stdoutPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        using var stderrFile = new FileStream(stderrPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        var stdout = child.StandardOutput.BaseStream.CopyToAsync(stdoutFile);
        var stderr = child.StandardError.BaseStream.CopyToAsync(stderrFile);
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(15));
        try { await Task.WhenAll(child.WaitForExitAsync(deadline.Token), stdout, stderr).WaitAsync(deadline.Token); }
        catch (OperationCanceledException)
        {
            if (!child.HasExited) child.Kill(entireProcessTree: true);
            throw new TimeoutException("Owned shader child process or output stream exceeded its timeout.");
        }
        return child.ExitCode;
    }

    private static bool ParentAlive(int id)
    {
        if (id == 0) return true;
        try { using var process = Process.GetProcessById(id); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }

    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--supervise-cook")
        {
            try { return await CookSupervisor.Run(args[1]); }
            catch (Exception error) { Console.Error.WriteLine("LIMELIGHT_STATUS Cook monitor failed: " + error.Message); return 1; }
        }
        try
        {
            var settings = JsonSerializer.Deserialize<AdapterSettings>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "ShaderAdapter.json"))) ?? throw new IOException("Missing adapter settings.");
            var project = Canonical(settings.ProjectRoot);
            if (!Under(AppContext.BaseDirectory, project)) throw new IOException("The compatibility worker must stay inside its cook copy.");
            if (!Under(settings.ProjectFile, project) || !File.Exists(settings.ProjectFile)) throw new IOException("Missing cook project.");
            var logs = Path.Combine(project, "Saved", "ShaderAdapter", "Logs");
            var workRoot = Path.Combine(project, "Saved", "ShaderAdapter", "Work");
            Directory.CreateDirectory(logs); Directory.CreateDirectory(workRoot);
            logPath = Path.Combine(logs, $"worker-{Environment.ProcessId}.jsonl");
            if (args.Length < 5) throw new IOException("Expected the UE shader worker task arguments.");
            var working = Canonical(args[0]);
            var tempShaders = Path.Combine(Path.GetTempPath(), "UnrealShaderWorkingDir");
            if (!Under(working, Path.Combine(project, "Intermediate")) && !Under(working, tempShaders)) throw new IOException($"Unexpected task directory: {working}");
            foreach (var fileName in args.Skip(3).Take(2))
                if (Path.GetFileName(fileName) != fileName || fileName.Contains("..")) throw new IOException("Task arguments must be file names within the working directory.");
            taskInput = Path.Combine(working, args[3]);
            taskOutput = Path.Combine(working, args[4]);
            var parentId = int.Parse(args[1]);
            Record(new { action = "boot", working, parentId, inputFile = args[3], outputFile = args[4] });
            using (var stream = File.OpenRead(settings.NativeWorker))
                if (Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)).ToLowerInvariant() != settings.NativeWorkerSha256) throw new IOException("Native shader worker version changed.");
            var once = args.Contains("--adapter-test-once");
            var cookProject = Environment.GetEnvironmentVariable("LIMELIGHT_SHADER_COOK_PROJECT");
            var token = Environment.GetEnvironmentVariable("LIMELIGHT_SHADER_COOK_TOKEN");
            var correctionEnabled = cookProject is not null && !string.IsNullOrEmpty(settings.CookToken)
                && token == settings.CookToken && Canonical(cookProject).Equals(Canonical(settings.ProjectFile), StringComparison.OrdinalIgnoreCase);
            if (!correctionEnabled)
            {
                Record(new { action = "normal-editor-pass-through", working, parentId });
                return await Run(settings.NativeWorker, args, working, Path.Combine(logs, $"native-{Environment.ProcessId}.stdout.txt"), Path.Combine(logs, $"native-{Environment.ProcessId}.stderr.txt"));
            }
            using (var stream = File.OpenRead(settings.AdapterScript))
                if (!Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)).Equals(settings.AdapterScriptSha256, StringComparison.OrdinalIgnoreCase)) throw new IOException("The task adapter changed after preparing this cook.");
            var input = Path.Combine(working, args[3]);
            var output = Path.Combine(working, args[4]);
            taskInput = input; taskOutput = output;
            var idle = Stopwatch.StartNew();
            Record(new { action = "start", working, parentId });
            var batch = 0;
            while (ParentAlive(parentId) && idle.Elapsed < TimeSpan.FromSeconds(600))
            {
                if (!File.Exists(input) || File.Exists(output)) { await Task.Delay(50); continue; }
                byte[] bytes;
                try
                {
                    using var file = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.None);
                    if (file.Length == 0) { await Task.Delay(50); continue; }
                    using var copy = new MemoryStream(); file.CopyTo(copy); bytes = copy.ToArray();
                }
                catch (IOException) { await Task.Delay(50); continue; }
                idle.Restart(); batch++;
                var job = Path.Combine(workRoot, $"worker-{Environment.ProcessId}", $"batch-{batch:D5}");
                Directory.CreateDirectory(job);
                var source = Path.Combine(job, "Original.in");
                var nativeInput = Path.Combine(job, args[3]);
                var nativeOutput = Path.Combine(job, args[4]);
                var reportPath = Path.Combine(job, "adapter-report.json");
                await File.WriteAllBytesAsync(source, bytes);
                var adapterCode = await Run(settings.Python, new[] { "-I", "-B", settings.AdapterScript, source, nativeInput, reportPath }, job, Path.Combine(job, "adapter.stdout.txt"), Path.Combine(job, "adapter.stderr.txt"));
                if (adapterCode != 0) throw new IOException($"Task adapter failed in {job}; exit {adapterCode}.");
                using var report = JsonDocument.Parse(File.ReadAllText(reportPath));
                var changed = report.RootElement.GetProperty("patched").GetArrayLength();
                Record(new { action = "adapted", batch, changed, report = report.RootElement.Clone() });
                var nativeArguments = new List<string> { job, args[1], args[2], args[3], args[4] };
                nativeArguments.AddRange(args.Skip(5).Where(a => !a.StartsWith("-TimeToLive=", StringComparison.OrdinalIgnoreCase) && a != "--adapter-test-once"));
                nativeArguments.AddRange(new[] { "-TimeToLive=0.0f", "-KeepInput", "-unattended", "-stdout" });
                var nativeCode = await Run(settings.NativeWorker, nativeArguments, job, Path.Combine(job, "native.stdout.txt"), Path.Combine(job, "native.stderr.txt"));
                if (nativeCode != 0)
                {
                    Record(new { action = "retry-native-worker", batch, nativeCode });
                    if (File.Exists(nativeOutput)) File.Move(nativeOutput, nativeOutput + ".attempt-1", overwrite: true);
                    nativeCode = await Run(settings.NativeWorker, nativeArguments, job, Path.Combine(job, "native-retry.stdout.txt"), Path.Combine(job, "native-retry.stderr.txt"));
                }
                if (nativeCode != 0 || !File.Exists(nativeOutput)) throw new IOException($"Native shader worker failed in {job}; exit {nativeCode}.");
                var nativeBytes = await File.ReadAllBytesAsync(nativeOutput);
                if (nativeBytes.Length < 16 || BitConverter.ToInt32(nativeBytes, 0) != 28 || BitConverter.ToInt32(nativeBytes, 12) != 0) throw new IOException($"Native shader worker reported a task error in {job}.");
                // I only consume the exact task file supplied by this cook.
                File.Delete(input);
                var temporaryOutput = output + ".adapter-" + Environment.ProcessId;
                await File.WriteAllBytesAsync(temporaryOutput, nativeBytes);
                File.Move(temporaryOutput, output, overwrite: true);
                idle.Restart();
                Record(new { action = "completed", batch, jobs = report.RootElement.GetProperty("jobs").GetInt32(), changed, outputBytes = nativeBytes.Length, evidence = changed > 0 && settings.KeepShaderDebug ? job : null });
                if (changed == 0 || !settings.KeepShaderDebug)
                {
                    var resolvedJob = Canonical(job);
                    if (!Under(resolvedJob, workRoot) || (File.GetAttributes(resolvedJob) & FileAttributes.ReparsePoint) != 0) throw new IOException("Unsafe worker cleanup path.");
                    Directory.Delete(resolvedJob, recursive: true);
                }
                if (once) return 0;
            }
            Record(new { action = "exit", batch });
            return 0;
        }
        catch (Exception error)
        {
            try { if (logPath.Length > 0) Record(new { action = "fatal", timedOut = error is TimeoutException, error = error.ToString() }); }
            catch (IOException logError) { Console.Error.WriteLine("Could not write worker log: " + logError.Message); }
            try { await ReportFailure(error); }
            catch (Exception handoffError) { Console.Error.WriteLine("Could not publish worker failure: " + handoffError.Message); }
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}
