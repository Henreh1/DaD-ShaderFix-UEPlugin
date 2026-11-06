param(
    [Parameter(Mandatory=$true)][string]$EngineRoot,
    [string]$OutputFolder
)
$ErrorActionPreference = 'Stop'
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
if (!(Test-Path -LiteralPath (Join-Path $EngineRoot 'Engine\Build\BatchFiles\RunUAT.bat') -PathType Leaf)) { throw 'Choose the Unreal Engine installation folder containing Engine\Build\BatchFiles\RunUAT.bat.' }
$pluginRoot = Split-Path -Parent $PSScriptRoot
if (!$OutputFolder) { $OutputFolder = Join-Path (Split-Path -Parent $pluginRoot) 'artifacts\LimelightShaderCooker-UE5.7.4-Win64' }
if (Test-Path -LiteralPath $OutputFolder) { throw 'Choose a new output folder; previous builds are not overwritten.' }
$buildLogs = Join-Path $pluginRoot ('artifacts\Build-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($buildLogs)
$env:uebp_LogFolder = $buildLogs
$env:uebp_FinalLogFolder = $buildLogs
$env:uebp_EngineSavedFolder = Join-Path $buildLogs 'AutomationSaved'
$env:UnrealBuildTool_BuildConfiguration__bAllowUBAExecutor = 'false'
$workerRoot = Join-Path $PSScriptRoot 'ShaderWorker'
$env:DOTNET_CLI_HOME = Join-Path $workerRoot '.dotnet-home'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
Push-Location $workerRoot
try {
    & dotnet build 'ShaderCompileWorker.csproj' -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Shader worker build failed.' }
} finally { Pop-Location }
$payload = Join-Path $pluginRoot 'Resources\Cooker\Worker'
[void][IO.Directory]::CreateDirectory($payload)
foreach ($name in @('ShaderCompileWorker.exe','ShaderCompileWorker.dll','ShaderCompileWorker.deps.json','ShaderCompileWorker.runtimeconfig.json')) {
    Copy-Item -LiteralPath (Join-Path $workerRoot ('bin\Release\net8.0\' + $name)) -Destination (Join-Path $payload $name)
}
$buildBases = @([IO.Path]::GetTempPath(), (Join-Path (Split-Path -Parent $pluginRoot) 'artifacts'))
$buildBase = $buildBases | Sort-Object Length | Select-Object -First 1
$buildRoot = Join-Path $buildBase ('sc-' + [guid]::NewGuid().ToString('N').Substring(0,6))
# I build the host project under a short path because UBT still checks MAX_PATH.
& (Join-Path $EngineRoot 'Engine\Build\BatchFiles\RunUAT.bat') BuildPlugin ('-Plugin=' + (Join-Path $pluginRoot 'LimelightShaderCooker.uplugin')) ('-Package=' + $buildRoot) '-TargetPlatforms=Win64' '-NoP4' '-UTF8Output'
if ($LASTEXITCODE -ne 0) { throw ('Editor plugin build failed: ' + $LASTEXITCODE) }
Copy-Item -LiteralPath $buildRoot -Destination $OutputFolder -Recurse
Write-Output ('Plugin built: ' + $OutputFolder)
