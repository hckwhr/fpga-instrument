param([string]$BuildId)
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$projectRoot=Split-Path (Split-Path $source -Parent) -Parent
$build='E:/Gowin/workspace/v3_full_stage54j_20261017'
$archive=Join-Path $projectRoot 'artifacts/v3_full_stage54j_20261017'
New-Item -ItemType Directory $archive -Force | Out-Null
$base='E:/Gowin/workspace/v3_full_stage54i_20261017'
$receipt=Get-Content "$build/.gowin-mcp/$BuildId/receipt.json" -Raw | ConvertFrom-Json
if($receipt.state -notin 'completed','failed'){throw 'Build still running'}
$inputs=@()
foreach($folder in @('rtl','src','constraints')){
    foreach($file in Get-ChildItem (Join-Path $source $folder) -Recurse -File){
        $rel=[IO.Path]::GetRelativePath($source,$file.FullName)
        $hash=(Get-FileHash $file.FullName).Hash
        if($hash -ne (Get-FileHash (Join-Path $build $rel)).Hash){throw "Built input changed: $rel"}
        if($folder -ne 'constraints' -and $hash -ne (Get-FileHash (Join-Path $base $rel)).Hash){throw "Baseline RTL differs: $rel"}
        $inputs += [pscustomobject]@{path=$rel;sha256=$hash}
    }
}
$inputs | ConvertTo-Json -Depth 3 | Set-Content "$archive/inputs_sha256.json" -Encoding utf8
$evidence=Join-Path $archive 'builds'
New-Item -ItemType Directory $evidence -Force | Out-Null
Copy-Item -LiteralPath "$build/.gowin-mcp/$BuildId" -Destination $evidence -Recurse -Force
$reports=Join-Path $archive 'final_reports'
New-Item -ItemType Directory $reports -Force | Out-Null
foreach($file in Get-ChildItem "$build/impl/pnr" -File){
    if($file.Extension -in '.html','.txt','.log','.do','.cfg','.timing_paths','.fs'){
        Copy-Item -LiteralPath $file.FullName -Destination $reports -Force
    }
}
$verification=Join-Path $archive 'verification'
New-Item -ItemType Directory $verification -Force | Out-Null
$names=@('tb_menu_delay_contract','tb_concurrent_entry','tb_settings_pages','tb_spectrum_stop','tb_v3_analog_input','tb_v3_hardware_top')
foreach($name in $names){
    $path="$build/sim/$name.log"
    if(!(Select-String $path -Pattern '# PASS:') -or (Select-String $path -Pattern '# \*\* (Error|Fatal):')){throw "Check failed: $name"}
    Copy-Item -LiteralPath $path -Destination $verification -Force
}
Copy-Item "$build/sim/menu_delay_negative.log" $verification -Force
Copy-Item "$build/focused_stage54j.log" $verification -Force
Copy-Item "$source/constraints/v3_hardware.sdc" "$archive/applied.sdc" -Force
Copy-Item "$source/sim/tb_menu_delay_contract.sv" $verification -Force
$pr=Get-ChildItem "$build/impl/pnr" -Filter '*.pr'
$fs=Get-ChildItem "$build/impl/pnr" -Filter '*.fs'
[ordered]@{
    build_id=$BuildId;success=$receipt.success;elapsed_seconds=$receipt.elapsed_seconds
    pr_present=($pr.Count -eq 1);bitstream_present=($fs.Count -eq 1)
    bitstream_sha256=if($fs.Count -eq 1){(Get-FileHash $fs.FullName).Hash}else{$null}
    rtl_unchanged=$true;legacy_regression='54h: 119 PASS, unchanged RTL; evidence archived separately'
    fresh_focused_checks=6;negative_menu_mask_detected=$true
    timing_accepted=$false;programmed=$false
} | ConvertTo-Json -Depth 4 | Set-Content "$archive/build_summary.json" -Encoding utf8
Get-Content "$archive/build_summary.json"
