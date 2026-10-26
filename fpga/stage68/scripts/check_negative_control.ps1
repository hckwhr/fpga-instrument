param([string]$BuildRoot='E:/Gowin/workspace/v3_hardware_stage51_20261015')
# Legacy 74HC165 prototype test only; this does not certify the actual dual-ADC V3 path.
$ErrorActionPreference='Stop'
Push-Location $BuildRoot
try {
    $result=& E:/modelsim/win64/vsim.exe -c work.tb_v3_latency_slow_scan -l sim/v3_latency_negative.transcript -wlf sim/v3_latency_negative.wlf -do 'run -all; quit -f' 2>&1
    $exitCode=$LASTEXITCODE
    $result | Set-Content negative_control_legacy_stage51.log -Encoding utf8
    if(!($result -match '# \*\* Fatal: V3 onset gate failed') -or ($result -match '# PASS:')){
        throw "Slow scan did not fail the intended gate (exit $exitCode)"
    }
    $result | Select-String 'Fatal:|Time:'
    Write-Output 'EXPECTED FAILURE: slow production scan rejected by the 5 ms gate.'
} finally {Pop-Location}

