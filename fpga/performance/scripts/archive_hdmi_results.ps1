$ErrorActionPreference = 'Stop'
$candidate = Split-Path $PSScriptRoot -Parent
$build = 'E:/Gowin/workspace/v3_hdmi_stage66e_20261025'
$archive = Join-Path (Split-Path (Split-Path $candidate -Parent) -Parent) 'artifacts/v3_hdmi_stage66e_20261025'
$regression = Join-Path $build 'full_regression_stage66e.log'
$names = @(Select-String -LiteralPath $regression -Pattern '^PASS (tb_\w+)$' | ForEach-Object {$_.Matches[0].Groups[1].Value} | Sort-Object -Unique)
if ($names.Count -ne 144 -or (Select-String -LiteralPath $regression -Pattern '^FAIL ')) { throw 'Expected 144 passing regression cases' }
$inputs = @()
foreach ($folder in @('rtl','src')) {
    foreach ($file in Get-ChildItem (Join-Path $candidate $folder) -Recurse -File) {
        if ($file.Extension -notin '.v','.vh','.mem','.hex','.mod','.ipc') { continue }
        $relative = [IO.Path]::GetRelativePath($candidate,$file.FullName)
        $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
        if ($hash -ne (Get-FileHash -LiteralPath (Join-Path $build $relative)).Hash) { throw "Build input differs: $relative" }
        $inputs += [pscustomobject]@{path=$relative;sha256=$hash}
    }
}
foreach ($name in @('constraints/v3_hdmi.sdc','constraints/v3_hdmi.cst','v3_hdmi_top.gprj')) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $candidate $name)).Hash
    if ($hash -ne (Get-FileHash -LiteralPath (Join-Path $build $name)).Hash) { throw "Applied project/constraint differs: $name" }
    $inputs += [pscustomobject]@{path=$name;sha256=$hash}
}
New-Item -ItemType Directory -Path "$archive/regression","$archive/synthesis","$archive/pnr" -Force | Out-Null
foreach ($name in $names + @('tb_hdmi_serializer','tb_hdmi_clock_startup','tb_hdmi_startup_contract')) {
    $log = Join-Path $build "sim/$name.log"
    if (!(Select-String -LiteralPath $log -Pattern '# PASS:') -or (Select-String -LiteralPath $log -Pattern '# ERROR:|# \*\* (Error|Fatal):')) { throw "Invalid bench: $name" }
    Copy-Item -LiteralPath $log -Destination "$archive/regression/" -Force
}
Copy-Item -LiteralPath $regression -Destination "$archive/regression/" -Force
foreach ($folder in @('gwsynthesis','pnr')) {
    $destination = if ($folder -eq 'gwsynthesis') {"$archive/synthesis"} else {"$archive/pnr"}
    Get-ChildItem "$build/impl/$folder" -File | Where-Object Extension -in '.html','.txt','.xml','.log','.do','.cfg','.fs' | Copy-Item -Destination $destination -Force
}
Copy-Item -LiteralPath "$build/pnr_stage66e.log" -Destination "$archive/pnr/" -Force
Copy-Item -LiteralPath "$build/synthesis_stage66e.log" -Destination "$archive/synthesis/" -Force
$routeFiles = @(Get-ChildItem "$build/impl/pnr" -Filter '*.pr' -File)
$outputBase = if ($routeFiles.Count -eq 1) {$routeFiles[0].BaseName} else {'project'}
$outputs = foreach ($name in @("$outputBase.pr","${outputBase}_tr_content.html","$outputBase.pin.html","$outputBase.fs")) {
    $path = Join-Path $build "impl/pnr/$name"
    $present = (Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 0
    [pscustomobject]@{path=$path;present=$present;sha256=if($present){(Get-FileHash -LiteralPath $path).Hash}else{$null}}
}
$inputs | ConvertTo-Json -Depth 4 | Set-Content "$archive/inputs_sha256.json" -Encoding utf8
$outputs | ConvertTo-Json -Depth 4 | Set-Content "$archive/output_inventory.json" -Encoding utf8
# Inventory and regression are evidence, not a timing or hardware acceptance.
Write-Output "Archived 144 regressions, 3 official PHY checks, inputs and build evidence to $archive"
$outputs | Format-Table -AutoSize
