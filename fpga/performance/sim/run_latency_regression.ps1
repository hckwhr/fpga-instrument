param(
    [Parameter(Mandatory=$true)][string]$ReferenceCsv,
    [string]$ModelSimBin='E:/modelsim/win64'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$reference=(Resolve-Path $ReferenceCsv).Path
$runDir=Join-Path ([System.IO.Path]::GetTempPath()) ('gowin_adsr_latency_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDir | Out-Null
Copy-Item (Join-Path $projectRoot 'rtl') $runDir -Recurse
Copy-Item (Join-Path $PSScriptRoot 'tb_latency_audit.v') $runDir
[xml]$project=(Get-Content (Join-Path $projectRoot 'fpga_instrument_av.gprj') -Raw) -replace '^<\?xml[^>]+\?>',''
$sources=@($project.Project.FileList.File | Where-Object {
    $_.enable -eq '1' -and $_.type -eq 'file.verilog' -and $_.path -notmatch 'audio_pll/|lcd_pll/|src/pll_init'
} | ForEach-Object {$_.path})
Push-Location $runDir
try {
    & "$ModelSimBin/vlib.exe" work
    if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    & "$ModelSimBin/vlog.exe" '+incdir+rtl' @sources tb_latency_audit.v
    if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    & "$ModelSimBin/vsim.exe" -c work.tb_latency_audit -l latency.log -do 'run -all; quit -f'
    if($LASTEXITCODE -ne 0){throw 'vsim failed'}
    $log=Get-Content latency.log -Raw
    if($log -notmatch 'PASS: 272 production top latency cases' -or $log -match '\*\* (Error|Fatal):') {
        throw 'Latency regression failed'
    }
    if((Get-FileHash latency.csv).Hash -ne (Get-FileHash $reference).Hash){throw 'Onset latency changed'}
    Copy-Item latency.csv (Join-Path $projectRoot 'sim/latency.csv')
    Copy-Item latency.log (Join-Path $projectRoot 'sim/tb_latency_audit.log')
    Write-Output 'PASS: all 272 latency records sample-exact to stage 14; initial response unchanged'
} finally {Pop-Location}
