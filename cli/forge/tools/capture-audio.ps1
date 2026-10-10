param(
    [Parameter(Mandatory=$true)][string]$Out,
    [Parameter(Mandatory=$true)][string]$ReadyPath,
    [Parameter(Mandatory=$true)][string]$LogFile,
    [Parameter(Mandatory=$true)][string]$CancelEvent,
    [ValidateRange(1,600000)][int]$Ms = 180000
)
$ErrorActionPreference = 'Stop'
# Fresh paths make an old READY or old WAV impossible to mistake for this run.
$paths = @($Out, $ReadyPath, ($ReadyPath + '.pending'), $LogFile)
$resolved = @($paths | ForEach-Object { [IO.Path]::GetFullPath($_) })
if (@($resolved | Select-Object -Unique).Count -ne $resolved.Count) {
    throw 'Output, ready, temporary-ready and log paths must differ.'
}
foreach ($path in $resolved) {
    if (Test-Path -LiteralPath $path) { throw "Evidence already exists: $path" }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($path)) -PathType Container)) {
        throw "Parent directory must exist: $path"
    }
}
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'ForgeQAAudio.cs')
    $result = [ForgeQAAudio.Loopback]::Capture($resolved[0], $Ms, $resolved[1], $CancelEvent)
    [IO.File]::WriteAllText($resolved[3], $result + "`nSTATUS=OK`n")
    Write-Output 'CAPTURE_COMPLETE'
} catch {
    [IO.File]::WriteAllText($resolved[3], "STATUS=FAIL`n" + $_.Exception.ToString())
    Write-Error $_
    exit 1
}
