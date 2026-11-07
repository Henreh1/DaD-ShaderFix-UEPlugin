param(
    [Parameter(Mandatory=$true)][string]$Request,
    [switch]$ValidateOnly,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$consoleWriter = $null
$projectMutex = $null
$mutexHeld = $false
$result = $null
$resultPath = $null
$exitCode = 1
$workspaceReady = $false

function Status([string]$Text) {
    Write-Output ('LIMELIGHT_STATUS ' + $Text)
    if ($script:consoleWriter) { $script:consoleWriter.WriteLine($Text) }
}

function Canonical([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '["%&|<>^!\r\n]') {
        throw 'A path is empty or contains characters unsupported by the Windows UAT batch launcher.'
    }
    $full = [IO.Path]::GetFullPath($Value).TrimEnd('\','/')
    if ($full -match '^[A-Za-z]:$') { $full += '\' }
    return $full
}

function Under([string]$Path, [string]$Root) {
    return (Canonical $Path).StartsWith((Canonical $Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Digest([string]$Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}

function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 14), $script:utf8)
}

try {
    . (Join-Path $PSScriptRoot 'Native-Build.ps1')
    . (Join-Path $PSScriptRoot 'Cook-Results.ps1')
    . (Join-Path $PSScriptRoot 'Workspace.ps1')
    . (Join-Path $PSScriptRoot 'Cook-Recovery.ps1')
    $requestData = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
    $profile = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $projectFile = Canonical $requestData.Project
    $sourceRoot = Split-Path -Parent $projectFile
    $engineRoot = Canonical $requestData.Engine
    $outputRoot = Canonical $requestData.OutputRoot
    $workRoot = Canonical $requestData.WorkRoot
    $runId = [string]$requestData.RunId
    if ($runId -notmatch '^\d{8}-\d{6}-[a-f0-9]{8}$') { throw 'Invalid cook run identifier.' }
    if (!(Test-Path -LiteralPath $projectFile -PathType Leaf) -or [IO.Path]::GetExtension($projectFile) -ne '.uproject') { throw 'The selected .uproject does not exist.' }
    if ($outputRoot -eq $engineRoot -or (Under $outputRoot $engineRoot)) { throw 'Choose an output folder outside the engine installation.' }
    foreach ($folder in @('Content','Config','Source','Binaries','Plugins','Build')) {
        $sourceFolder = Join-Path $sourceRoot $folder
        if ($outputRoot -eq $sourceFolder -or (Under $outputRoot $sourceFolder)) { throw 'Choose an output folder outside project source and content folders.' }
    }
    $mode = if ($requestData.PSObject.Properties['Mode']) { [string]$requestData.Mode } else { 'Folder' }
    if ($mode -notin @('Asset','Map','Folder','All')) { throw 'Unknown cook mode.' }
    if ($requestData.PSObject.Properties['ArenaCook'] -and $requestData.ArenaCook -isnot [bool]) { throw 'ArenaCook must be a JSON boolean.' }
    $arenaCook = $mode -eq 'Map' -or ($requestData.PSObject.Properties['ArenaCook'] -and $requestData.ArenaCook)
    $contentFolder = if ($mode -eq 'Folder') { ([string]$requestData.ContentFolder).Replace('\','/').TrimEnd('/') } else { '/Game' }
    if ($contentFolder -ne '/Game' -and !$contentFolder.StartsWith('/Game/')) { throw 'The cook folder must start with /Game/.' }
    if ($contentFolder -match '(^|/)\.{1,2}(/|$)') { throw 'The cook folder contains dot segments.' }
    $relativeContent = if ($contentFolder -eq '/Game') { '' } else { $contentFolder.Substring(6) }
    $sourceContent = Canonical (Join-Path (Join-Path $sourceRoot 'Content') $relativeContent)
    if (!(Test-Path -LiteralPath $sourceContent -PathType Container)) { throw 'The selected content folder does not exist.' }
    if ($sourceContent -ne (Join-Path $sourceRoot 'Content') -and !(Under $sourceContent (Join-Path $sourceRoot 'Content'))) { throw 'The content folder escaped the project.' }
    $assetPackage = ''
    $assetPackages = @()
    $mapPackages = @()
    if ($mode -in @('Asset','Map')) {
        $assetPackage = [string]$requestData.AssetPackage
        if (!$assetPackage.StartsWith('/Game/') -or $assetPackage -match '["%&|<>^!+\s:\\.]') { throw 'Choose a valid /Game/... asset or map package.' }
        $rootExtension = if ($mode -eq 'Map') { '.umap' } else { '.uasset' }
        $assetFile = Join-Path (Join-Path $sourceRoot 'Content') ($assetPackage.Substring(6) + $rootExtension)
        if (!(Test-Path -LiteralPath $assetFile -PathType Leaf)) { throw 'The selected asset or map does not exist on disk. Save it before cooking.' }
        $assetPackages = @(if ($requestData.PSObject.Properties['AssetPackages']) { $requestData.AssetPackages } else { $assetPackage })
        if (!$assetPackages.Count) { throw 'The selected data asset or label did not resolve to any packages to cook.' }
        foreach ($package in $assetPackages) {
            if (!$package.StartsWith('/Game/') -or $package -match '["%&|<>^!+\s:\\.]') { throw 'The selected asset resolved to an unsupported package path.' }
            $packageBase = Join-Path (Join-Path $sourceRoot 'Content') $package.Substring(6)
            if (Test-Path -LiteralPath ($packageBase + '.umap') -PathType Leaf) { $mapPackages += $package }
            elseif (!(Test-Path -LiteralPath ($packageBase + '.uasset') -PathType Leaf)) { throw ('A selected cook package does not exist: ' + $package) }
        }
        $assetPackages = @($assetPackages | Sort-Object -Unique)
        if ($mode -eq 'Map' -and $assetPackage -notin $mapPackages) { throw 'The requested map is missing from the selected cook packages.' }
    } elseif ($mode -eq 'Folder' -and $arenaCook) {
        $contentRoot = (Join-Path $sourceRoot 'Content').TrimEnd('\') + '\'
        $mapPackages = @(Get-ChildItem -LiteralPath $sourceContent -Filter '*.umap' -Recurse -File | ForEach-Object {
            '/Game/' + $_.FullName.Substring($contentRoot.Length, $_.FullName.Length - $contentRoot.Length - 5).Replace('\','/')
        })
    }
    $mapPackages = @($mapPackages | Sort-Object -Unique)
    if ($mapPackages.Count -and !$arenaCook) { throw 'The selected label includes maps. Enable Cook as an arena, or select a character-only label.' }
    foreach ($mapPackage in $mapPackages) {
        if (!$mapPackage.StartsWith('/Game/') -or $mapPackage -match '["%&|<>^!+\s:\\.]') { throw 'A selected map has an unsupported package path.' }
    }
    $requestedPackages = @(@($assetPackages) + @($mapPackages) | Sort-Object -Unique)
    $runFolder = Join-Path $outputRoot $runId
    if (Test-Path -LiteralPath $runFolder) { throw 'The output run folder already exists; refusing to reuse it.' }
    [void][IO.Directory]::CreateDirectory($runFolder)
    $resultPath = Join-Path $runFolder 'Result.json'
    $consoleWriter = New-Object IO.StreamWriter((Join-Path $runFolder 'Console.txt'), $false, $utf8)
    $consoleWriter.AutoFlush = $true
    $result = [ordered]@{RunId=$runId;StartedUtc=[datetime]::UtcNow.ToString('o');Profile=$profile.id;Project=$projectFile;Mode=$mode;ContentFolder=$contentFolder;AssetPackage=$assetPackage;Succeeded=$false;Phase='Preflight';SourceMaterialsChanged=$false;SourceConfigChanged=$false}
    $result['RequestedPackages'] = $requestedPackages
    $result['RequestedMaps'] = $mapPackages
    $result['ArenaCook'] = [bool]$arenaCook
    $result['CookedContentVersioning'] = if ($arenaCook) { 'TaggedProperties' } else { 'EngineDefault' }
    $stallSeconds = if ($requestData.PSObject.Properties['ShaderStallSeconds']) { [int]$requestData.ShaderStallSeconds } else { 900 }
    if ($stallSeconds -lt 1 -or $stallSeconds -gt 7200) { throw 'ShaderStallSeconds must be between 1 and 7200.' }
    $result['ShaderStallSeconds'] = $stallSeconds
    Status 'Checking engine and cooker files...'
    $engineBuild = Get-Content -LiteralPath (Join-Path $engineRoot 'Engine\Build\Build.version') -Raw | ConvertFrom-Json
    if ($engineBuild.MajorVersion -ne $profile.engineMajor -or $engineBuild.MinorVersion -ne $profile.engineMinor -or $engineBuild.PatchVersion -ne $profile.enginePatch -or $engineBuild.Changelist -ne $profile.engineChangelist) {
        throw 'This compatibility profile requires the tested Epic UE 5.7.4 engine (CL-51494982).'
    }
    $nativeWorker = Join-Path $engineRoot 'Engine\Binaries\Win64\ShaderCompileWorker.exe'
    if ((Digest $nativeWorker) -ne $profile.nativeWorkerSha256) { throw 'The engine shader worker differs from the tested compatibility profile.' }
    $projectDescription = Get-Content -LiteralPath $projectFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $needsGameBinaries = $projectDescription.PSObject.Properties['Modules'] -and @($projectDescription.Modules | Where-Object { $_.Type -in @('Runtime','RuntimeNoCommandlet','RuntimeAndProgram','ClientOnly','ClientOnlyNoCommandlet') }).Count
    $receipts = @(Get-DevelopmentGameReceipts $projectFile $engineBuild)
    $result['DevelopmentReceipts'] = $receipts
    $result['NativeBuildRequired'] = [bool]($needsGameBinaries -and !$receipts.Count)
    $result['NativeBuildStarted'] = $false
    if ($result.NativeBuildRequired) { $result['NativeBuildArguments'] = @(Get-DevelopmentBuildArguments $projectFile) }
    $python = Join-Path $engineRoot 'Engine\Binaries\ThirdParty\Python3\Win64\python.exe'
    $oodle = Join-Path $engineRoot 'Engine\Binaries\DotNET\AutomationTool\oo2core_9_win64.dll'
    $uat = Join-Path $engineRoot 'Engine\Build\BatchFiles\RunUAT.bat'
    $dotnet = @(Get-ChildItem -LiteralPath (Join-Path $engineRoot 'Engine\Binaries\ThirdParty\DotNet') -Filter dotnet.exe -Recurse -File | Where-Object { $_.FullName -match '\\8\.[^\\]+\\win-x64\\dotnet.exe$' })
    if (!$dotnet.Count) { throw 'The engine bundled .NET 8 runtime was not found.' }
    $workerFiles = @('ShaderCompileWorker.exe','ShaderCompileWorker.dll','ShaderCompileWorker.deps.json','ShaderCompileWorker.runtimeconfig.json')
    $progressPayload = Join-Path $PSScriptRoot 'ProgressProbe'
    $progressFiles = @('LimelightCookProgress.uplugin','Binaries\Win64\UnrealEditor-LimelightCookProgress.dll','Binaries\Win64\UnrealEditor.modules')
    foreach ($file in @($python,$oodle,$uat) + @($workerFiles | ForEach-Object { Join-Path (Join-Path $PSScriptRoot 'Worker') $_ }) + @($progressFiles | ForEach-Object { Join-Path $progressPayload $_ })) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw ('Required cooker file missing: ' + $file) }
    }
    $adapterPath = Join-Path $PSScriptRoot 'task_adapter.py'
    $adapterHash = Digest $adapterPath
    $fingerprintInput = $adapterHash + (Digest (Join-Path $PSScriptRoot 'format-versions.json')) + (Digest (Join-Path $PSScriptRoot 'translucent-layout.json')) + (Digest (Join-Path $PSScriptRoot 'opaque-layout.json')) + (Digest (Join-Path $PSScriptRoot 'profile.json')) + (Digest (Join-Path $PSScriptRoot 'Worker\ShaderCompileWorker.dll'))
    $fingerprintAlgorithm = [Security.Cryptography.SHA256]::Create()
    try { $profileFingerprint = [BitConverter]::ToString($fingerprintAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintInput))).Replace('-','').ToLowerInvariant().Substring(0,24) }
    finally { $fingerprintAlgorithm.Dispose() }
    $cacheRoot = Join-Path $workRoot ('Cache\' + $profileFingerprint)
    if ($cacheRoot.Length -ge 119) { throw 'The private shader cache path is too long. Choose a shorter WorkRoot.' }
    if ($cacheRoot -eq $sourceRoot -or (Under $cacheRoot $sourceRoot) -or (Under $sourceRoot $cacheRoot) -or $cacheRoot -eq $engineRoot -or (Under $cacheRoot $engineRoot)) { throw 'The private cache must be separate from the source project and engine.' }
    Assert-PhysicalWorkspacePath $cacheRoot
    $projectHash = [Security.Cryptography.SHA256]::Create()
    try { $projectKey = [BitConverter]::ToString($projectHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectFile.ToLowerInvariant()))).Replace('-','').Substring(0,24) }
    finally { $projectHash.Dispose() }
    $copyRoot = Join-Path $workRoot ('Projects\' + $projectKey)
    if ($copyRoot -eq $sourceRoot -or (Under $copyRoot $sourceRoot) -or (Under $sourceRoot $copyRoot) -or (Under $copyRoot $engineRoot)) { throw 'The cook workspace must be separate from the source project and engine.' }
    if ($outputRoot -eq $copyRoot -or (Under $outputRoot $copyRoot)) { throw 'Choose an output folder outside the reusable cook workspace.' }
    Assert-PhysicalWorkspacePath $copyRoot
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'Binaries\Win64\ShaderCompileWorker.exe')) { throw 'This project already overrides ShaderCompileWorker. Use its original project or a clean project copy.' }
    if ($ValidateOnly) {
        $result.Phase = 'Validated'
        $result['StartsCook'] = $false
        $result['PrivateCache'] = $cacheRoot
        $exitCode = 0
    } else {
        $projectMutex = New-Object Threading.Mutex($false, ('Local\LimelightShaderCooker.' + $projectKey))
        try { $mutexHeld = $projectMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
        if (!$mutexHeld) { throw 'Another compatibility cook is already using this project.' }
        if ($result.NativeBuildRequired -and !$PrepareOnly) {
            Status 'Building the missing Win64 Development game binaries. This step needs the Visual Studio C++ build tools and Windows SDK.'
            $result.Phase = 'BuildingDevelopment'
            $result.NativeBuildStarted = $true
            $buildLog = Join-Path $runFolder 'NativeBuild.txt'
            $result['NativeBuildLog'] = $buildLog
            Write-Json $resultPath $result
            $nativeExitCode = Invoke-DevelopmentGameBuild $projectFile $engineRoot $buildLog $consoleWriter
            $result['NativeBuildExitCode'] = $nativeExitCode
            if ($nativeExitCode -ne 0) { throw ('The Development game build failed with exit code ' + $nativeExitCode + '. See NativeBuild.txt for compiler errors. If the C++ tools are missing, install Visual Studio Game development with C++ and a Windows SDK, then retry Cook Mod.') }
            $receipts = @(Get-DevelopmentGameReceipts $projectFile $engineBuild)
            if (!$receipts.Count) { throw 'The build returned success without a usable Win64 Development Game receipt and executable for this project. See NativeBuild.txt.' }
            $result.DevelopmentReceipts = $receipts
            $result.NativeBuildRequired = $false
            Status 'Development game binaries are ready.'
        }
        Status 'Preparing a project copy. Please leave source assets unchanged until cooking starts...'
        $result['WorkspaceReused'] = Initialize-CookWorkspace $copyRoot $projectFile
        $workspaceReady = $true
        Save-WorkspaceDiagnostics (Join-Path $runFolder 'PreviousCookDiagnostics') $true ([IO.Path]::GetFileNameWithoutExtension($projectFile))
        Reset-CookWorkspace
        $script:copiedFiles = 0
        $script:reusedFiles = 0
        $script:removedItems = 0
        $projectFolders = @('Config','Content','Source','Build','Binaries','Plugins')
        foreach ($item in Get-ChildItem -LiteralPath $copyRoot -Force) {
            if ($item.Name -notin ($projectFolders + @('.limelight-workspace.json', [IO.Path]::GetFileName($projectFile)))) { Remove-WorkspaceItem $item.FullName }
        }
        foreach ($folder in $projectFolders) {
            $sourceFolder = Join-Path $sourceRoot $folder
            Sync-WorkspaceDirectory $sourceFolder (Join-Path $copyRoot $folder)
        }
        $copyProject = Join-Path $copyRoot ([IO.Path]::GetFileName($projectFile))
        Sync-WorkspaceFile $projectFile $copyProject
        $projectJson = Get-Content -LiteralPath $copyProject -Raw -Encoding UTF8 | ConvertFrom-Json
        $projectPlugins = if ($projectJson.PSObject.Properties['Plugins']) { @($projectJson.Plugins | Where-Object { $_.Name -notin @('LimelightShaderCooker','LimelightCookProgress') }) } else { @() }
        $projectPlugins = @($projectPlugins) + @([pscustomobject]@{Name='LimelightCookProgress';Enabled=$true;TargetAllowList=@('Editor')})
        $projectJson | Add-Member -NotePropertyName Plugins -NotePropertyValue $projectPlugins -Force
        Write-Json $copyProject $projectJson
        $probeTarget = Join-Path $copyRoot 'Plugins\LimelightCookProgress'
        Remove-WorkspaceItem $probeTarget
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $probeTarget))
        Assert-PhysicalWorkspaceTree $progressPayload
        Copy-Item -LiteralPath $progressPayload -Destination $probeTarget -Recurse
        $result['CookProgressEnabled'] = $true
        $cacheName = 'LimelightShaderCookerDDC'
        $enginePak = Join-Path $engineRoot 'Engine\DerivedDataCache\Compressed.ddp'
        $graph = "`r`n`r`n[$cacheName]`r`nRoot=(Type=KeyLength, Length=120, Inner=AsyncPut)`r`nAsyncPut=(Type=AsyncPut, Inner=Hierarchy)`r`n"
        $graph += if (Test-Path -LiteralPath $enginePak) { "Hierarchy=(Type=Hierarchical, Inner=EnginePak, Inner=Local)`r`n" } else { "Hierarchy=(Type=Hierarchical, Inner=Local)`r`n" }
        $graph += 'Local=(Type=FileSystem, ReadOnly=false, Clean=true, Flush=false, DeleteUnused=true, UnusedFileAge=14, FoldersToClean=10, Path="' + $cacheRoot.Replace('\','/') + '")' + "`r`n"
        if (Test-Path -LiteralPath $enginePak) { $graph += 'EnginePak=(Type=ReadPak, Filename="' + $enginePak.Replace('\','/') + '", Compressed=true)' + "`r`n" }
        $graph += "`r`n[DevOptions.Shaders]`r`nbUseShaderCompilerFromLaunchDir=False`r`nbAllowCompilingThroughWorkers=True`r`n"
        [void][IO.Directory]::CreateDirectory((Join-Path $copyRoot 'Config'))
        $engineIni = Join-Path $copyRoot 'Config\DefaultEngine.ini'
        $originalConfig = if (Test-Path -LiteralPath $engineIni) { [IO.File]::ReadAllText($engineIni) } else { '' }
        [IO.File]::WriteAllText($engineIni, $originalConfig + $graph, $utf8)
        $gameIni = Join-Path $copyRoot 'Config\DefaultGame.ini'
        $gameConfig = if (Test-Path -LiteralPath $gameIni) { [IO.File]::ReadAllText($gameIni) } else { '' }
        $cookAll = if ($mode -eq 'All') { 'True' } else { 'False' }
        $packaging = "`r`n[/Script/UnrealEd.ProjectPackagingSettings]`r`nbCookAll=$cookAll`r`n"
        if ($mode -eq 'All') { $packaging += "bCookMapsOnly=False`r`n" }
        [IO.File]::WriteAllText($gameIni, $gameConfig + $packaging, $utf8)
        $binaryRoot = Join-Path $copyRoot 'Binaries\Win64'
        [void][IO.Directory]::CreateDirectory($binaryRoot)
        foreach ($file in $workerFiles) { [IO.File]::Copy((Join-Path (Join-Path $PSScriptRoot 'Worker') $file), (Join-Path $binaryRoot $file), $false) }
        $cookToken = [guid]::NewGuid().ToString('N')
        $settings = [ordered]@{ProjectRoot=$copyRoot;ProjectFile=$copyProject;Python=$python;AdapterScript=$adapterPath;AdapterScriptSha256=$adapterHash;NativeWorker=$nativeWorker;NativeWorkerSha256=$profile.nativeWorkerSha256;CookToken=$cookToken;KeepShaderDebug=[bool]$requestData.ShaderDebug}
        Write-Json (Join-Path $binaryRoot 'ShaderAdapter.json') $settings
        $result['CookProject'] = $copyProject
        $result['CopiedFiles'] = $copiedFiles
        $result['ReusedFiles'] = $reusedFiles
        $result['RemovedWorkspaceItems'] = $removedItems
        $result['PrivateCache'] = $cacheRoot
        $result['NullRhi'] = $true
        $result.Phase = 'Prepared'
        $forceVars = 'r.ShaderCompiler.JobCacheDDC=0'
        if ($requestData.ShaderDebug) { $forceVars += ',r.DumpShaderDebugInfo=1,r.DumpShaderDebugShortNames=1' }
        $additionalOptions = '-NoDefaultMaps -NoMaterialShaderDDC -ForceGenerateAllChunksInfo -DDC=' + $cacheName + ' -NullRHI -ForceDPCVars=' + $forceVars
        $cookRoots = @()
        if ($mode -eq 'Folder') { $cookRoots += '-CookDir=' + (Join-Path (Join-Path $copyRoot 'Content') $relativeContent) }
        elseif ($mode -in @('Asset','Map')) { $additionalOptions += ' -Package=' + ($assetPackages -join '+') }
        else { $cookRoots += '-CookAll' }
        if ($arenaCook) {
            $cookRoots += '-VersionCookedContent'
            if ($mapPackages.Count) { $cookRoots += '-map=' + ($mapPackages -join '+') }
        }
        $arguments = @('-WaitForUATMutex','BuildCookRun',('-project=' + $copyProject),'-targetplatform=Win64','-clientconfig=Development','-nocompileeditor','-skipbuildeditor','-cook') + $cookRoots + @(('-AdditionalCookerOptions=' + $additionalOptions),'-stage','-pak','-iostore','-manifests','-package','-archive',('-archivedirectory=' + (Join-Path $runFolder 'Build')),'-nop4','-utf8output')
        $result['Arguments'] = $arguments
        Write-Json $resultPath $result
        if ($PrepareOnly) {
            $result['StartsCook'] = $false
            Status 'Project copy prepared; no cook requested.'
            $exitCode = 0
        } else {
            $env:LIMELIGHT_SHADER_COOK_PROJECT = $copyProject
            $env:LIMELIGHT_SHADER_COOK_TOKEN = $cookToken
            $env:LIMELIGHT_SHADER_OODLE = $oodle
            $env:DOTNET_ROOT = $dotnet[0].DirectoryName
            $env:PYTHONUTF8 = '1'
            $env:uebp_LogFolder = Join-Path $runFolder 'UATLogs'
            $env:uebp_FinalLogFolder = $env:uebp_LogFolder
            $env:uebp_EngineSavedFolder = Join-Path $runFolder 'AutomationSaved'
            foreach ($folder in @($env:uebp_LogFolder, $env:uebp_EngineSavedFolder)) { [void][IO.Directory]::CreateDirectory($folder) }
            $result.Phase = 'Cooking'
            Write-Json $resultPath $result
            Status 'Cooking the saved project copy. You can continue editing the source project.'
            $exitCode = Invoke-CookWithRecovery $uat $arguments $copyProject $runFolder $PSScriptRoot $result $consoleWriter $stallSeconds
            $result['UatExitCode'] = $exitCode
            if ($exitCode -ne 0) {
                if ($result.Contains('ShaderWorkerFailure')) { throw ('Shader compilation stopped: ' + $result.ShaderWorkerFailure.Detail + ' See CookMonitor reports and preserved worker diagnostics.') }
                throw ('UAT failed with exit code ' + $exitCode + '. See Console.txt and UATLogs.')
            }
            Status 'Checking packaged files and shader-worker reports...'
            $consoleWriter.Flush()
            $materialWarnings = @(Get-CookMaterialWarnings (Join-Path $runFolder 'Console.txt'))
            $result['MaterialWarnings'] = $materialWarnings
            $cookedPackages = @(Get-CookedPackageNames $copyProject)
            $result['CookedPackageCount'] = $cookedPackages.Count
            $result['CookedGamePackages'] = @($cookedPackages | Where-Object { $_.StartsWith('/Game/') })
            $missingPackages = @(Get-MissingCookPackages $cookedPackages $requestedPackages)
            $result['MissingRequestedPackages'] = $missingPackages
            if ($missingPackages.Count) { throw ('The cook omitted selected packages: ' + ($missingPackages -join ', ') + '. The output is not a complete mod.') }
            if ($mode -eq 'Folder' -and !@($cookedPackages | Where-Object { $_.StartsWith($contentFolder + '/', [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'The cook produced no packages from the selected content folder.' }
            $files = @(Get-ChildItem -LiteralPath (Join-Path $runFolder 'Build') -Recurse -File | Where-Object { $_.Extension -in @('.pak','.utoc','.ucas') })
            $pakFiles = @($files | Where-Object { $_.Extension -eq '.pak' -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName,'.utoc'))) -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName,'.ucas'))) })
            if (!$pakFiles.Count) { throw 'UAT returned success without a matching pak/utoc/ucas set.' }
            $patchedJobs = 0
            $workerLogRoot = Join-Path $copyRoot 'Saved\ShaderAdapter\Logs'
            if (Test-Path -LiteralPath $workerLogRoot) {
                foreach ($logFile in Get-ChildItem -LiteralPath $workerLogRoot -Filter 'worker-*.jsonl' -File) {
                    foreach ($line in Get-Content -LiteralPath $logFile.FullName) {
                        $entry = $line | ConvertFrom-Json
                        if ($entry.detail.action -eq 'fatal') { throw ('Shader worker failed: ' + $entry.detail.error) }
                        if ($entry.detail.action -eq 'completed') { $patchedJobs += [int]$entry.detail.changed }
                    }
                }
            }
            $result['PatchedShaderJobs'] = $patchedJobs
            $result['Files'] = @($files | ForEach-Object { [ordered]@{Path=$_.FullName;Bytes=$_.Length;Sha256=(Digest $_.FullName)} })
            $result['PakDirectories'] = @($pakFiles.DirectoryName | Sort-Object -Unique)
            $result.Succeeded = $true
            $result.Phase = 'Completed'
            if ($materialWarnings.Count) { Status ('Cook completed with material warnings. Check Result.json. Corrected shader jobs: ' + $patchedJobs) }
            else { Status ('Cook completed. Corrected shader jobs: ' + $patchedJobs + '. Packaged files are in Build.') }
        }
    }
} catch {
    $exitCode = if ($exitCode -eq 0) { 1 } else { $exitCode }
    $message = $_.Exception.Message
    if ($result) { $result['Error'] = $message; $result.Phase = 'Failed' }
    Status ('Cook failed: ' + $message)
} finally {
    if ($workspaceReady -and $mutexHeld -and !$PrepareOnly) {
        try {
            Save-WorkspaceDiagnostics $runFolder ([bool]$requestData.ShaderDebug -or !$result.Succeeded) ([IO.Path]::GetFileNameWithoutExtension($projectFile))
            $result['DiagnosticsSavedToOutput'] = $true
            if ($result.Succeeded) { Reset-CookWorkspace; $result['CookScratchRemoved'] = $true }
        } catch {
            $result['StorageWarning'] = $_.Exception.Message
            Status ('Cook workspace cleanup needs attention: ' + $_.Exception.Message)
        }
    }
    if ($result -and $resultPath) { $result['FinishedUtc'] = [datetime]::UtcNow.ToString('o'); $result['ExitCode'] = $exitCode; Write-Json $resultPath $result }
    if ($consoleWriter) { $consoleWriter.Dispose() }
    if ($mutexHeld) { $projectMutex.ReleaseMutex() }
    if ($projectMutex) { $projectMutex.Dispose() }
}
exit $exitCode
