$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $root 'SOURCE_MANIFEST.json'
$origins = @{}
foreach ($entry in (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)) {
    $origins[$entry.destination] = $entry
}
$files = @(git -C $root -c core.quotepath=false ls-files --cached --others --exclude-standard) | Sort-Object -Unique
if ($LASTEXITCODE -ne 0) { throw 'Cannot list repository files' }
$result = foreach ($relative in $files) {
    if ($relative -eq 'SOURCE_MANIFEST.json') { continue }
    $origin = $origins[$relative]
    $hash = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
    $originalHash = if ($origin.source_sha256) { $origin.source_sha256 } else { $origin.sha256 }
    if ($relative.StartsWith('fpga/') -and $originalHash -and $hash -ne $originalHash) { throw "Accepted FPGA input changed: $relative" }
    [ordered]@{destination=$relative; source=$origin.source; source_sha256=$originalHash; packaged_sha256=$hash}
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
Write-Output "Manifest updated: $($result.Count) files; accepted FPGA inputs unchanged."
