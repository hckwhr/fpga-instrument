$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'SOURCE_MANIFEST.json') -Raw | ConvertFrom-Json
$failures = @()
foreach ($entry in $manifest) {
    $file = Join-Path $root $entry.destination
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        $failures += "Missing: $($entry.destination)"
    } elseif ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.packaged_sha256) {
        $failures += "Changed: $($entry.destination)"
    }
}
if ($failures.Count) { $failures | Write-Output; throw "Manifest mismatch: $($failures.Count) files" }
Write-Output "PASS: $($manifest.Count) packaged files match SHA256 manifest (manifest itself excluded)."
