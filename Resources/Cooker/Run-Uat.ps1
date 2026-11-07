param([Parameter(Mandatory=$true)][string]$Plan)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$data = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
$uat = [string]$data.Uat
$uatArguments = @($data.Arguments | ForEach-Object { [string]$_ })
$ErrorActionPreference = 'Continue'
& $uat @uatArguments 2>&1 | ForEach-Object { [Console]::WriteLine($_.ToString()) }
exit $(if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 })
