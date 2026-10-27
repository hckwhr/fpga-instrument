param([Parameter(Mandatory)][string]$BuildId,
    [string]$BuildRoot='E:/Gowin/workspace/v3_telemetry_stage62_20261021',
    [string]$RegressionRoot='')
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$root=Split-Path (Split-Path $source -Parent) -Parent
$build=$BuildRoot
if(!$RegressionRoot){$RegressionRoot=$build}
$archive=Join-Path $root 'artifacts/v3_telemetry_stage62_20261021'
$receipt=Get-Content "$build/.gowin-mcp/$BuildId/receipt.json" -Raw | ConvertFrom-Json
if($receipt.state -notin 'completed','failed'){throw 'Build still running'}
$fullLog="$RegressionRoot/full_regression_stage62.log"
$names=@(Select-String $fullLog -Pattern '^PASS (tb_\w+)$' | ForEach-Object {$_.Matches[0].Groups[1].Value})
if(($names | Sort-Object -Unique).Count -ne 132 -or (Select-String $fullLog -Pattern '^FAIL |# \*\* (Error|Fatal):')){throw 'Expected all 132 benches to pass'}
$inputs=@()
foreach($folder in @('rtl','src','constraints')){
    foreach($file in Get-ChildItem (Join-Path $source $folder) -Recurse -File){
        $rel=[IO.Path]::GetRelativePath($source,$file.FullName)
        $hash=(Get-FileHash $file.FullName).Hash
        if($hash -ne (Get-FileHash (Join-Path $build $rel)).Hash){throw "Built input differs: $rel"}
        if($hash -ne (Get-FileHash (Join-Path $RegressionRoot $rel)).Hash){throw "Regression input differs: $rel"}
        $inputs += [pscustomobject]@{path=$rel;sha256=$hash}
    }
}
$clocks=@(Get-Content "$source/constraints/v3_hardware.sdc" | Where-Object {$_ -match '^create_(generated_)?clock\s'})
$baseClocks=@(Get-Content "$source/../v3_full_stage54g_20261016/constraints/v3_hardware.sdc" | Where-Object {$_ -match '^create_(generated_)?clock\s'})
if($clocks.Count -ne 3 -or (Compare-Object $clocks $baseClocks)){throw 'Three clock definitions changed'}
if((Get-FileHash "$source/constraints/v3_hardware.cst").Hash -ne '5367030C1F687132DEBF47B50AF959884282A8D2E4CC80D19A8769BBF1BA6775'){throw '45-pin CST changed'}
New-Item -ItemType Directory "$archive/regression","$archive/builds","$archive/final_reports" -Force | Out-Null
foreach($name in $names){
    $log="$RegressionRoot/sim/$name.log"
    if(!(Select-String $log -Pattern '# PASS:') -or (Select-String $log -Pattern '# ERROR:|# \*\* (Error|Fatal):')){throw "Invalid bench: $name"}
    Copy-Item -LiteralPath $log -Destination "$archive/regression" -Force
}
foreach($mutation in @(1,2)){
    $log="$RegressionRoot/sim/pin_negative_$mutation.log"
    if(!(Select-String $log -Pattern '# \*\* Fatal: Board key 0 failed through physical input/audio selection') -or (Select-String $log -Pattern '# PASS:')){throw "Missing expected negative control: $mutation"}
    Copy-Item -LiteralPath $log -Destination "$archive/regression" -Force
}
Copy-Item -LiteralPath $fullLog -Destination $archive -Force
Copy-Item -LiteralPath "$build/.gowin-mcp/$BuildId" -Destination "$archive/builds" -Recurse -Force
foreach($file in Get-ChildItem "$build/impl/pnr" -File){
    if($file.Extension -in '.html','.txt','.log','.do','.cfg','.timing_paths','.fs'){
        Copy-Item -LiteralPath $file.FullName -Destination "$archive/final_reports" -Force
    }
}
Copy-Item -LiteralPath "$build/impl/gwsynthesis/v3_hardware_top_syn_rsc.xml" -Destination $archive -Force
Copy-Item -LiteralPath "$source/constraints/v3_hardware.sdc" -Destination "$archive/applied.sdc" -Force
$inputs | ConvertTo-Json -Depth 3 | Set-Content "$archive/inputs_sha256.json" -Encoding utf8
$fs=@(Get-ChildItem "$build/impl/pnr" -Filter '*.fs')
[ordered]@{
    build_id=$BuildId;build_success=$receipt.success
    build_root=$build;regression_root=$RegressionRoot
    elapsed_seconds=[math]::Round(($receipt.finished_epoch - $receipt.started_epoch),3)
    regression_passed=132;baseline_benches_retained=130;new_scope_benches=2
    current_or_module_checks=109;retained_legacy_engine_checks=23
    pin_negative_controls_rejected=2;clock_definitions_unchanged=$true;cst_unchanged=$true
    pr_present=(@(Get-ChildItem "$build/impl/pnr" -Filter '*.pr').Count -eq 1)
    bitstream_present=($fs.Count -eq 1)
    bitstream_sha256=if($fs.Count -eq 1){(Get-FileHash $fs[0].FullName).Hash}else{$null}
    acceptance='See validation.md and fresh timing/pin audits; bitstream presence alone is not acceptance'
    programmed=$false;hardware_observed=$false
} | ConvertTo-Json -Depth 4 | Set-Content "$archive/build_summary.json" -Encoding utf8
Get-Content "$archive/build_summary.json"
