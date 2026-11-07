function Invoke-CookWithRecovery([string]$Uat, [string[]]$Arguments, [string]$CookProject, [string]$RunFolder, [string]$PayloadRoot, $Result, $ConsoleWriter, [int]$StallSeconds = 900) {
    $attempts = New-Object 'Collections.Generic.List[object]'
    $currentArguments = $Arguments
    $supervisor = Join-Path $PayloadRoot 'Worker\ShaderCompileWorker.exe'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $env:uebp_LogFolder = Join-Path $RunFolder ('UATLogs\attempt-' + $attempt)
        $env:uebp_FinalLogFolder = $env:uebp_LogFolder
        $env:uebp_EngineSavedFolder = Join-Path $RunFolder ('AutomationSaved\attempt-' + $attempt)
        foreach ($path in @($env:uebp_LogFolder, $env:uebp_EngineSavedFolder)) { [void][IO.Directory]::CreateDirectory($path) }
        $plan = [ordered]@{ProjectRoot=(Split-Path -Parent $CookProject);RunFolder=$RunFolder;Uat=$Uat;Arguments=$currentArguments;AutomationFolder=$env:uebp_EngineSavedFolder;Attempt=$attempt;StallSeconds=$StallSeconds}
        $planPath = Join-Path $RunFolder ('CookPlan-attempt-' + $attempt + '.json')
        Write-Json $planPath $plan
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $supervisor '--supervise-cook' $planPath 2>&1 | ForEach-Object { $line = $_.ToString(); $ConsoleWriter.WriteLine($line); [Console]::WriteLine($line) }
            $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
        } finally { $ErrorActionPreference = $previousPreference }
        $reportPath = Join-Path $RunFolder ('CookMonitor-attempt-' + $attempt + '.json')
        $report = if (Test-Path -LiteralPath $reportPath) { Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        $attempts.Add([ordered]@{Attempt=$attempt;ExitCode=$code;Monitor=$reportPath;Arguments=$currentArguments})
        $Result['CookAttempts'] = @($attempts.ToArray())
        $Result['Arguments'] = $currentArguments
        if ($report) { $Result['ShaderProgress'] = $report }
        Write-Json (Join-Path $RunFolder 'Result.json') $Result
        $canRetry = $code -eq 86 -and $report -and $report.Reason -in @('ShaderWorkersStalled','WorkerExitedWithoutOutput')
        if (!$canRetry -or $attempt -eq 2) {
            if ($code -ne 0 -and $report -and $report.Reason) { $Result['ShaderWorkerFailure'] = $report }
            return $code
        }
        $message = 'LIMELIGHT_STATUS Shader compilation stalled. Saving diagnostics and retrying once with reduced parallelism; compatibility correction remains enabled.'
        $ConsoleWriter.WriteLine($message)
        [Console]::WriteLine($message)
        $Result.Phase = 'RecoveringShaderWorkers'
        Write-Json (Join-Path $RunFolder 'Result.json') $Result
        $archive = Join-Path $RunFolder 'StalledAttempt1'
        Save-WorkspaceDiagnostics $archive $true ([IO.Path]::GetFileNameWithoutExtension($CookProject))
        $build = Join-Path $RunFolder 'Build'
        if (Test-Path -LiteralPath $build) {
            if (!(Under $build $RunFolder)) { throw 'Invalid partial build path.' }
            Assert-PhysicalWorkspacePath $build
            Assert-PhysicalWorkspaceTree $build
            [void][IO.Directory]::CreateDirectory($archive)
            Move-Item -LiteralPath $build -Destination (Join-Path $archive 'Build')
        }
        Reset-CookWorkspace
        $currentArguments = @($Arguments | ForEach-Object { if ($_.StartsWith('-AdditionalCookerOptions=')) { $_ + ' -corelimit=1' } else { $_ } })
        $Result.Phase = 'Cooking'
        $Result['ShaderWorkerRecoveryUsed'] = $true
    }
}
