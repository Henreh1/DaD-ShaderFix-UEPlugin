param([Parameter(Mandatory=$true)][string]$Plan, [switch]$ShowPhases)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$data = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
$uat = [string]$data.Uat
$uatArguments = @($data.Arguments | ForEach-Object { [string]$_ })
$ErrorActionPreference = 'Continue'
& $uat @uatArguments 2>&1 | ForEach-Object {
    $line = $_.ToString()
    [Console]::WriteLine($line)
    if ($ShowPhases -and $line -match '\*+ (STAGE|PACKAGE|ARCHIVE) COMMAND STARTED') {
        $phase = switch ($Matches[1]) {
            'STAGE' { 'Staging packaged files...' }
            'PACKAGE' { 'Packaging mod...' }
            'ARCHIVE' { 'Archiving packaged files...' }
        }
        [Console]::WriteLine('LIMELIGHT_STATUS ' + $phase)
    }
}
exit $(if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 })
