function Get-DevelopmentGameReceipts([string]$ProjectFile, $EngineBuild) {
    $projectRoot = Split-Path -Parent $ProjectFile
    $binaries = Join-Path $projectRoot 'Binaries\Win64'
    if (!(Test-Path -LiteralPath $binaries -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $binaries -Filter '*.target' -File) {
        try {
            $receipt = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($receipt.Configuration -ne 'Development' -or $receipt.Platform -ne 'Win64' -or $receipt.TargetType -ne 'Game') { continue }
            if ($receipt.Version.MajorVersion -ne $EngineBuild.MajorVersion -or $receipt.Version.MinorVersion -ne $EngineBuild.MinorVersion -or $receipt.Version.PatchVersion -ne $EngineBuild.PatchVersion -or $receipt.Version.Changelist -ne $EngineBuild.Changelist) { continue }
            $receiptProject = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $receipt.Project))
            if (!$receiptProject.Equals([IO.Path]::GetFullPath($ProjectFile), [StringComparison]::OrdinalIgnoreCase)) { continue }
            $launch = [string]$receipt.Launch
            if ([string]::IsNullOrWhiteSpace($launch)) { continue }
            $launch = $launch.Replace('$(ProjectDir)', $projectRoot)
            if (![IO.Path]::IsPathRooted($launch)) { $launch = Join-Path $file.DirectoryName $launch }
            $launch = [IO.Path]::GetFullPath($launch)
            if (!$launch.StartsWith($projectRoot.TrimEnd('\','/') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-Path -LiteralPath $launch -PathType Leaf) { $file.FullName }
        } catch {
            # I rebuild instead of trusting an incomplete or copied receipt.
            continue
        }
    }
}

function Get-DevelopmentBuildArguments([string]$ProjectFile) {
    return @('Development','Win64',('-Project=' + $ProjectFile),'-TargetType=Game','-WaitMutex','-NoUBA','-NoXGE','-NoEngineChanges','-NoHotReloadFromIDE')
}

function Invoke-DevelopmentGameBuild([string]$ProjectFile, [string]$EngineRoot, [string]$LogPath, $ConsoleWriter = $null) {
    $build = Join-Path $EngineRoot 'Engine\Build\BatchFiles\Build.bat'
    if (!(Test-Path -LiteralPath $build -PathType Leaf)) { throw ('The engine build launcher is missing: ' + $build) }
    $arguments = @(Get-DevelopmentBuildArguments $ProjectFile)
    $writer = New-Object IO.StreamWriter($LogPath, $false, (New-Object Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $build @arguments 2>&1 | ForEach-Object {
            $line = $_.ToString()
            $writer.WriteLine($line)
            if ($ConsoleWriter) { $ConsoleWriter.WriteLine($line) }
            [Console]::WriteLine($line)
        }
        return $(if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 })
    } finally {
        $ErrorActionPreference = $previousPreference
        $writer.Dispose()
    }
}
