param([string]$Workspace='E:/Gowin/workspace')
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path $PSScriptRoot -Parent
$projectRoot=Split-Path (Split-Path $sourceRoot -Parent) -Parent
$archive=Join-Path $projectRoot 'artifacts/v3_full_stage54g_20261016'
New-Item -ItemType Directory -Path $archive -Force | Out-Null
$e=Join-Path $projectRoot 'work/v3_full_stage54e_20261016'
$f=Join-Path $projectRoot 'work/v3_full_stage54f_20261016'
$sourceDiff=@()
foreach($folder in @('rtl','src','constraints')) {
    foreach($file in Get-ChildItem (Join-Path $e $folder) -Recurse -File) {
        $relative=[IO.Path]::GetRelativePath($e,$file.FullName)
        $eh=(Get-FileHash $file.FullName).Hash
        $fh=(Get-FileHash (Join-Path $f $relative)).Hash
        $gh=(Get-FileHash (Join-Path $sourceRoot $relative)).Hash
        if($eh -ne $fh -or $fh -ne $gh) {
            $sourceDiff += [pscustomobject]@{path=$relative;e=$eh;f=$fh;g=$gh}
        }
    }
}
if($sourceDiff.Count -ne 2 -or @($sourceDiff.path | Where-Object {$_ -notin @('rtl\av_top.v','rtl\polyphony_bank_32.v')}).Count) {
    throw 'Bisection is not isolated to the two expected RTL files'
}
$topology=@()
foreach($stage in @('54e','54f','54g')) {
    $root=Join-Path $Workspace "v3_full_stage${stage}_20261016"
    $vg=Join-Path $root 'impl/gwsynthesis/v3_hardware_top.vg'
    if(!(Test-Path $vg)){continue}
    $text=Get-Content $vg -Raw
    $poly=[regex]::Match($text,'(?ms)^module polyphony_bank_32(?:\s|\().*?^endmodule').Value
    if(!$poly){throw "Missing polyphony module in $vg"}
    $dsps=@([regex]::Matches($poly,'(?ms)^\s*MULTALU27X18\s+.*?^\);') |
        Where-Object {$_.Value -match '\.B\([^)]*pitch_delta[^)]*\)'})
    $selectors=@([regex]::Matches($poly,'\.(?:I[0-9]+|S[0-9]+)\(pitch_lane\[(?<bit>[0-9]+)\]\)') |
        Group-Object {$_.Groups['bit'].Value} | Sort-Object {[int]$_.Name} |
        ForEach-Object {[pscustomobject]@{bit=[int]$_.Name;primitive_input_pins=$_.Count}})
    $saturation=@([regex]::Matches($poly,'\.(?:I[0-9]+|S[0-9]+)\(shared_pitch_sum\[(?<bit>3[23])\]\)') |
        Group-Object {$_.Groups['bit'].Value} | Sort-Object Name |
        ForEach-Object {[pscustomobject]@{bit=[int]$_.Name;primitive_input_pins=$_.Count}})
    $phases=@([regex]::Matches($poly,'(?m)^\s*DFF\w*\s+\\phase_accumulator\[(\d+)\]_(\d+)_\w+\s+\(') |
        Group-Object {$_.Groups[1].Value} | Sort-Object {[int]$_.Name} |
        ForEach-Object {[pscustomobject]@{lane=[int]$_.Name;bits=$_.Count}})
    $envelopes=@([regex]::Matches($poly,'(?m)^\s*DFF\w*\s+\\envelope_gain\[(\d+)\]_(\d+)_\w+\s+\(') |
        Group-Object {$_.Groups[1].Value} | Sort-Object {[int]$_.Name} |
        ForEach-Object {[pscustomobject]@{lane=[int]$_.Name;bits=$_.Count}})
    $partials=[regex]::Matches($text,'(?m)^\s*additive_partial\w*\s+[^\r\n]*').Count
    $strings=[regex]::Matches($text,'(?m)^\s*physical_string_voice\w*\s+[^\r\n]*').Count
    if($stage -eq '54g' -and $dsps.Count -ne 17) {throw "Expected 17 pitch DSPs, got $($dsps.Count)"}
    if($phases.Count -ne 32 -or @($phases | Where-Object bits -ne 32).Count -or
       $envelopes.Count -ne 32 -or @($envelopes | Where-Object bits -ne 12).Count -or
       $partials -ne 32 -or $strings -ne 8) {throw "Independent voice-state count changed in $stage"}
    $topology += [pscustomobject]@{
        stage=$stage;netlist_sha256=(Get-FileHash $vg).Hash
        pitch_delta_multipliers=$dsps.Count;selector_loads=$selectors
        saturation_control_loads=$saturation
        independent_phases=$phases;independent_envelopes=$envelopes
        additive_partial_instances=$partials;physical_string_instances=$strings
    }
}
$result=[ordered]@{
    changed_rtl=$sourceDiff
    scope='Primitive input-pin counts in synthesized polyphony module; no claim about routed delay or failure causation'
    topology=$topology
    cst_sha256=(Get-FileHash (Join-Path $sourceRoot 'constraints/v3_hardware.cst')).Hash
    sdc_sha256=(Get-FileHash (Join-Path $sourceRoot 'constraints/v3_hardware.sdc')).Hash
}
$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $archive 'pitch_bisection_audit.json') -Encoding utf8
$result | ConvertTo-Json -Depth 8
