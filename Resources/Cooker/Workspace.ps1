function Assert-PhysicalWorkspacePath([string]$Path) {
    $cursor = Canonical $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($item.PSObject.Properties['LinkType'] -and $item.LinkType)) { throw ('Refusing a linked cook workspace path: ' + $cursor) }
        }
        $parent = Split-Path -Parent $cursor
        if (!$parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-WorkspaceTarget([string]$Path) {
    $target = Canonical $Path
    if (!(Under $target $script:workspaceRoot)) { throw ('Refusing a path outside the owned cook workspace: ' + $target) }
    Assert-PhysicalWorkspacePath $target
}

function Assert-PhysicalWorkspaceTree([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($item.PSObject.Properties['LinkType'] -and $item.LinkType)) { throw ('Refusing a linked item in the cook workspace: ' + $Path) }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) { Assert-PhysicalWorkspaceTree $child.FullName }
    }
}

function Remove-WorkspaceItem([string]$Path) {
    Assert-WorkspaceTarget $Path
    if (Test-Path -LiteralPath $Path) {
        Assert-PhysicalWorkspaceTree $Path
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Initialize-CookWorkspace([string]$Path, [string]$Project) {
    $script:workspaceRoot = Canonical $Path
    Assert-PhysicalWorkspacePath $workspaceRoot
    $marker = Join-Path $workspaceRoot '.limelight-workspace.json'
    $reused = Test-Path -LiteralPath $workspaceRoot
    if ($reused) {
        if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'The cook workspace exists without an ownership marker; refusing to change it.' }
        Assert-WorkspaceTarget $marker
        $owner = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($owner.Owner -ne 'LimelightShaderCooker' -or $owner.SchemaVersion -ne 1 -or
            (Canonical $owner.Project) -ne (Canonical $Project) -or (Canonical $owner.Workspace) -ne $workspaceRoot) {
            throw 'The cook workspace ownership marker does not match this project.'
        }
        Assert-PhysicalWorkspaceTree $workspaceRoot
    } else {
        [void][IO.Directory]::CreateDirectory($workspaceRoot)
        Write-Json $marker ([ordered]@{Owner='LimelightShaderCooker';SchemaVersion=1;Project=(Canonical $Project);Workspace=$workspaceRoot})
    }
    return [bool]$reused
}

function Sync-WorkspaceFile([string]$Source, [string]$Target) {
    Assert-WorkspaceTarget $Target
    $sourceHash = Digest $Source
    if ((Test-Path -LiteralPath $Target -PathType Leaf) -and (Digest $Target) -eq $sourceHash) {
        $script:reusedFiles++
        return
    }
    $temporary = $Target + '.copy-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        if ((Digest $temporary) -ne $sourceHash -or (Digest $Source) -ne $sourceHash) { throw ('A source file changed while refreshing the cook copy: ' + $Source) }
        if (Test-Path -LiteralPath $Target) { Remove-WorkspaceItem $Target }
        [IO.File]::Move($temporary, $Target)
        $attributes = [IO.File]::GetAttributes($Target) -band (-bnot [IO.FileAttributes]::ReadOnly)
        [IO.File]::SetAttributes($Target, $attributes)
        $script:copiedFiles++
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-WorkspaceItem $temporary }
    }
}

function Sync-WorkspaceDirectory([string]$Source, [string]$Target) {
    Assert-WorkspaceTarget $Target
    if (!(Test-Path -LiteralPath $Source -PathType Container)) { Remove-WorkspaceItem $Target; return }
    if ((Get-Item -LiteralPath $Source -Force).LinkType -in @('SymbolicLink','Junction')) { throw ('Linked project directories need a physical copy for this cook: ' + $Source) }
    if (Test-Path -LiteralPath $Target -PathType Leaf) { Remove-WorkspaceItem $Target }
    [void][IO.Directory]::CreateDirectory($Target)
    $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.PSIsContainer -and ($item.Name -in @('Saved','Intermediate','DerivedDataCache','.git','.vs','.idea') -or
            $item.FullName -eq (Join-Path $script:sourceRoot 'Plugins\LimelightShaderCooker') -or
            (Test-Path -LiteralPath (Join-Path $item.FullName 'LimelightShaderCooker.uplugin') -PathType Leaf))) { continue }
        if ($item.LinkType -in @('SymbolicLink','Junction')) { throw ('Linked project files need a physical copy for this cook: ' + $item.FullName) }
        [void]$names.Add($item.Name)
        $destination = Join-Path $Target $item.Name
        if ($item.PSIsContainer) { Sync-WorkspaceDirectory $item.FullName $destination }
        else { Sync-WorkspaceFile $item.FullName $destination }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Target -Force) {
        if (!$names.Contains($item.Name)) { Remove-WorkspaceItem $item.FullName; $script:removedItems++ }
    }
}

function Save-WorkspaceDiagnostics([string]$Destination, [bool]$KeepWork, [string]$ProjectName = '') {
    $paths = [ordered]@{'Saved\ShaderAdapter\Logs'='ShaderWorkerLogs';'Saved\Logs'='CookProjectLogs';'Saved\Crashes'='Crashes'}
    if ($KeepWork) {
        $paths['Saved\ShaderAdapter\Work'] = 'ShaderWorkerWork'
        $paths['Saved\ShaderDebugInfo'] = 'ShaderDebugInfo'
    }
    if ($ProjectName) { $paths[('Saved\Cooked\Windows\' + $ProjectName + '\Metadata')] = 'CookMetadata' }
    foreach ($relative in $paths.Keys) {
        $source = Join-Path $script:workspaceRoot $relative
        if (!(Test-Path -LiteralPath $source)) { continue }
        Assert-WorkspaceTarget $source
        Assert-PhysicalWorkspaceTree $source
        $target = Canonical (Join-Path $Destination $paths[$relative])
        if (!(Under $target $Destination) -or (Test-Path -LiteralPath $target)) { throw 'The diagnostic destination is invalid or already exists.' }
        [void][IO.Directory]::CreateDirectory($Destination)
        Assert-PhysicalWorkspacePath $Destination
        Move-Item -LiteralPath $source -Destination $target
    }
}

function Reset-CookWorkspace {
    foreach ($name in @('Saved','Intermediate','DerivedDataCache')) { Remove-WorkspaceItem (Join-Path $script:workspaceRoot $name) }
}
