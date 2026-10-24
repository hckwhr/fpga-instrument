param([string]$BuildRoot='E:/Gowin/workspace/v3_full_stage54i_20261017',
      [string]$RegressionRoot='E:/Gowin/workspace/v3_full_stage54h_20261016')
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path $PSScriptRoot -Parent
$projectRoot=Split-Path (Split-Path $sourceRoot -Parent) -Parent
$archiveRoot=Join-Path $projectRoot 'artifacts/v3_full_stage54i_20261017'
$inputs=@()
foreach($folder in @('rtl','src','sim','scripts','constraints')){
    foreach($file in Get-ChildItem (Join-Path $sourceRoot $folder) -Recurse -File){
        if($file.Extension -notin '.v','.sv','.vh','.mem','.hex','.ps1','.py','.json','.tcl','.cst','.sdc'){continue}
        $relative=[IO.Path]::GetRelativePath($sourceRoot,$file.FullName)
        $built=Join-Path $BuildRoot $relative
        $hash=(Get-FileHash -LiteralPath $file.FullName).Hash
        if(!(Test-Path -LiteralPath $built) -or $hash -ne (Get-FileHash -LiteralPath $built).Hash){throw "Input differs: $relative"}
        if($folder -in @('rtl','src','sim') -and $file.Extension -in '.v','.sv','.vh','.mem','.hex'){
            $tested=Join-Path $RegressionRoot $relative
            if(!(Test-Path $tested) -or $hash -ne (Get-FileHash $tested).Hash){throw "Reused regression input differs: $relative"}
        }
        $inputs += [pscustomobject]@{path=$relative;sha256=$hash}
    }
}
foreach($name in @('v3_hardware_top.gprj','fpga_instrument_av.gprj')){
    $hash=(Get-FileHash -LiteralPath (Join-Path $sourceRoot $name)).Hash
    if($hash -ne (Get-FileHash -LiteralPath (Join-Path $BuildRoot $name)).Hash){throw "Project differs: $name"}
    $inputs += [pscustomobject]@{path=$name;sha256=$hash}
}
$fullLog=Join-Path $RegressionRoot 'full_regression_stage54h.log'
$names=@(Select-String -LiteralPath $fullLog -Pattern '^PASS (tb_\w+)$' | ForEach-Object {$_.Matches[0].Groups[1].Value})
if(($names | Sort-Object -Unique).Count -ne 119 -or (Select-String $fullLog -Pattern '^FAIL |# \*\* (Error|Fatal):')){throw 'Expected 119 passing benches (all original 116 retained)'}
$baselineLog=Join-Path (Split-Path $BuildRoot -Parent) 'v3_full_stage54g_20261016/full_regression_stage54g.log'
$baselineNames=@(Select-String -LiteralPath $baselineLog -Pattern '^PASS (tb_\w+)$' | ForEach-Object {$_.Matches[0].Groups[1].Value} | Sort-Object -Unique)
if($baselineNames.Count -ne 116 -or @($baselineNames | Where-Object {$_ -notin $names}).Count){throw 'Original 116-bench suite not retained'}
$sdcPath=Join-Path $sourceRoot 'constraints/v3_hardware.sdc'
$baselineSdc=Join-Path (Split-Path $sourceRoot -Parent) 'v3_full_stage54g_20261016/constraints/v3_hardware.sdc'
$clockPattern='^create_(generated_)?clock\s'
$clocks=@(Get-Content $sdcPath | Where-Object {$_ -match $clockPattern})
$baselineClocks=@(Get-Content $baselineSdc | Where-Object {$_ -match $clockPattern})
if($clocks.Count -ne 3 -or (Compare-Object $clocks $baselineClocks)){throw 'Three original clock definitions changed'}
if((Get-FileHash (Join-Path $sourceRoot 'constraints/v3_hardware.cst')).Hash -ne '5367030C1F687132DEBF47B50AF959884282A8D2E4CC80D19A8769BBF1BA6775'){throw '45-pin CST changed'}
$regression=Join-Path $archiveRoot 'regression'
New-Item -ItemType Directory -Path $regression -Force | Out-Null
foreach($name in $names){
    $log=Join-Path $RegressionRoot "sim/$name.log"
    if(!(Select-String $log -Pattern '# PASS:') -or (Select-String $log -Pattern '# ERROR:|# \*\* (Error|Fatal):')){throw "Invalid bench: $name"}
    if((Get-Item $log).LastWriteTimeUtc -lt (Get-Item $fullLog).CreationTimeUtc){throw "Stale bench: $name"}
    Copy-Item -LiteralPath $log -Destination $regression -Force
}
Copy-Item -LiteralPath $fullLog -Destination $archiveRoot -Force
foreach($mutation in @(1,2)) {
    $negativeLog=Join-Path $RegressionRoot "sim/pin_negative_$mutation.log"
    if(!(Select-String -LiteralPath $negativeLog -Pattern '# \*\* Fatal: Board key 0 failed through physical input/audio selection') -or
       (Select-String -LiteralPath $negativeLog -Pattern '# PASS:')) {throw "Missing expected pin fault detection: $mutation"}
    Copy-Item -LiteralPath $negativeLog -Destination $regression -Force
}
$csvEvidence=@()
foreach($capture in Get-ChildItem -LiteralPath (Join-Path $RegressionRoot 'sim') -Filter '*.csv'){
    $baseline=Join-Path 'E:/Gowin/workspace/v3_hardware_stage51_20261015/sim' $capture.Name
    if(!(Test-Path -LiteralPath $baseline)){continue}
    $hash=(Get-FileHash -LiteralPath $capture.FullName).Hash
    $baselineHash=(Get-FileHash -LiteralPath $baseline).Hash
    $csvEvidence += [pscustomobject]@{file=$capture.Name;sha256=$hash;stage51_sha256=$baselineHash;equal=($hash -eq $baselineHash)}
}
$csvEvidence | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $archiveRoot 'audio_csv_hashes.json') -Encoding utf8
if($csvEvidence.Count -ne 54 -or @($csvEvidence | Where-Object {-not $_.equal}).Count){throw 'Expected all 54 baseline CSVs to match'}
$builds=@()
foreach($receipt in Get-ChildItem (Join-Path $BuildRoot '.gowin-mcp') -Filter receipt.json -Recurse -File){
    $data=Get-Content $receipt.FullName -Raw | ConvertFrom-Json
    $destination=Join-Path $archiveRoot "builds/$($data.build_id)"
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $receipt.FullName -Destination $destination -Force
    foreach($name in @('build.log','build.tcl','reports')){
        $item=Join-Path $receipt.DirectoryName $name
        if(Test-Path -LiteralPath $item){Copy-Item -LiteralPath $item -Destination $destination -Recurse -Force}
    }
    $builds += [pscustomobject]@{build_id=$data.build_id;stage=$data.stage;state=$data.state;success=$data.success}
}
[xml]$resource=Get-Content -LiteralPath (Join-Path $BuildRoot 'impl/gwsynthesis/project_syn_rsc.xml') -Raw
function ResourceCount([string]$name){
    $value=$resource.Module.GetAttribute($name)
    if(!$value){return 0}
    return [int]($value -replace '\(.*','')
}
$lut=ResourceCount 'T_Lut'
$alu=ResourceCount 'T_Alu'
$ssram=ResourceCount 'T_Ssram'
$summary=[ordered]@{
    regression_passed=$names.Count
    regression_reused_from=$RegressionRoot
    regression_rtl_test_memory_hashes_verified=$true
    legacy_module_regression_passed=@($names | Where-Object {$_ -in @('tb_audio_voice_mixer','tb_dds_control_pipeline','tb_expression_audition','tb_expression_slew','tb_integration_routing','tb_mixer_pipeline','tb_pitch_expression','tb_smooth_audio')}).Count
    pin_negative_controls_rejected=2
    csv_compared=$csvEvidence.Count
    csv_equal=@($csvEvidence | Where-Object equal).Count
    hardware='12 FSR channels, U2 CH4 Y / CH5 X / CH6 pot; no 74HC165'
    right_word_latency_one_simulated_case_ms=([double]([regex]::Match((Get-Content (Join-Path $RegressionRoot 'sim/tb_v3_hardware_top.log') -Raw),'right word ([0-9.]+) ms').Groups[1].Value))
    latency_scope='one 12-key stimulus at production clocks, not a phase sweep or physical measurement'
    aggregate_force_latency_engine_steps=4
    shared_force_minimum_strobe_interval_engine_steps=33
    shared_force_production_strobe_interval_engine_steps=512
    shared_force_additional_live_latency_max_audio_slots=1
    shared_pitch_minimum_strobe_interval_engine_steps=64
    shared_pitch_lanes=16
    parallel_pitch_lanes=16
    shared_pitch_production_strobe_interval_engine_steps=512
    physical_clocks_per_stereo_frame=1024
    baseline_clock_definitions_unchanged=$true
    pt8211_protocol_evidence='tb_v3_hardware_top: BCK half period 16, 32 BCK/frame, 16-bit left then right, exact PCM words, no missing/duplicate engine samples'
    half_rate_added_benches=@('tb_half_rate_pitch','tb_half_rate_force','tb_half_rate_datapaths')
    half_rate_pcm_scope='10000 physical 1024-clock sample slots compare string hybrid FILL/feedback, additive32 and all effects against CE-disabled full-speed modules; shared pitch/force compare frozen references'
    synthesis=[ordered]@{logic=$lut+$alu+6*$ssram;lut_including_inverters=$lut;alu=$alu;registers=(ResourceCount 'T_Register');bsram=(ResourceCount 'T_Bsram');ssram=$ssram}
    synthesis_dsp=[ordered]@{multalu27x18=(ResourceCount 'T_MULTALU27X18');mult12x12=(ResourceCount 'T_MULT12X12');mult27x36=(ResourceCount 'T_MULT27X36')}
    synthesized_legacy_mixer_instances=@($resource.SelectNodes('//SubModule') | Where-Object name -match 'u_audio_voice_mixer').Count
    builds=$builds
    timing_accepted=$false
    programmed=$false
    hardware_observed=$false
}
$inputs | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $archiveRoot 'inputs_sha256.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $archiveRoot 'results.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 6

