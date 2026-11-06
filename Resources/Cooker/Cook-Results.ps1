function Get-CookMaterialWarnings([string]$LogPath) {
    $stream = New-Object IO.FileStream($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        $warnings = New-Object 'Collections.Generic.HashSet[string]'
        while (!$reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -match 'Failed to compile Material|Default Material will be used') { [void]$warnings.Add($line) }
        }
        $warnings | Sort-Object
    } finally { $reader.Dispose() }
}

function Get-CookedPackageNames([string]$CookProject) {
    $projectName = [IO.Path]::GetFileNameWithoutExtension($CookProject)
    $metadata = Join-Path (Split-Path -Parent $CookProject) ('Saved\Cooked\Windows\' + $projectName + '\Metadata\AllChunksInfo.csv')
    if (!(Test-Path -LiteralPath $metadata -PathType Leaf)) { throw 'The cook package inventory is missing. Selected content could not be verified.' }
    $rows = @(Import-Csv -LiteralPath $metadata)
    if (!$rows.Count) { throw 'The cook package inventory is empty.' }
    $column = @($rows[0].PSObject.Properties.Name | Where-Object { $_.Trim() -eq 'Package Name' })
    if ($column.Count -ne 1) { throw 'The cook package inventory has an unexpected format.' }
    $rows | ForEach-Object { [string]$_.$($column[0]) } | Where-Object { $_.StartsWith('/') } | Sort-Object -Unique
}

function Get-MissingCookPackages([string[]]$CookedPackages, [string[]]$RequestedPackages) {
    foreach ($package in $RequestedPackages) {
        if ($package -notin $CookedPackages) { $package }
    }
}
