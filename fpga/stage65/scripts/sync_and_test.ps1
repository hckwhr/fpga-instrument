param([string]$Log='full_regression_stage65.log',[switch]$Focused,[string[]]$Benches,[switch]$SyncOnly)
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$target='E:/Gowin/workspace/v3_instrumental_stage65_20261024'
New-Item -ItemType Directory -Path $target -Force | Out-Null
foreach($folder in @('rtl','src','sim','scripts','constraints')){
    foreach($file in Get-ChildItem (Join-Path $source $folder) -Recurse -File){
        if($file.Extension -notin '.v','.sv','.vh','.hex','.mem','.ps1','.py','.json','.tcl','.cst','.sdc'){continue}
        $destination=Join-Path $target ([IO.Path]::GetRelativePath($source,$file.FullName))
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}
foreach($name in @('fpga_instrument_av.gprj','v3_hardware_top.gprj')){
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $target -Force
}
if($SyncOnly){return}
Push-Location $target
try {
    if($Benches){./sim/run_dynamic_regression.ps1 -Jobs 12 -Benches $Benches *> $Log}
    elseif($Focused){./sim/run_dynamic_regression.ps1 -Jobs 6 -Benches tb_poly_pitch_shared,tb_poly_pitch_fast_strobe,tb_poly_pitch_half_shared,tb_poly_pitch_half_fast_strobe,tb_poly_stage54_exact,tb_v3_hardware_top,tb_poly_glide,tb_poly_force_shared *> $Log}
    else{./sim/run_dynamic_regression.ps1 -Jobs 12 *> $Log}
} finally {Get-Content $Log -Tail 30;Pop-Location}

