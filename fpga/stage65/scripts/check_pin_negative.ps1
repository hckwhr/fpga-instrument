param([string]$BuildRoot='E:/Gowin/workspace/v3_telemetry_stage62_20261021')
$ErrorActionPreference='Stop'
Push-Location $BuildRoot
try {
    foreach($mutation in @(1,2)) {
        $result=& E:/modelsim/win64/vsim.exe -c work.tb_v3_hardware_top "-gMUTATION=$mutation" -l "sim/pin_negative_$mutation.transcript" -wlf "sim/pin_negative_$mutation.wlf" -do 'run -all; quit -f' 2>&1
        $result | Set-Content "sim/pin_negative_$mutation.log" -Encoding utf8
        if(!($result -match '# \*\* Fatal: Board key 0 failed through physical input/audio selection') -or ($result -match '# PASS:')) {
            throw "Pin mutation $mutation did not fail the intended physical input gate"
        }
        $result | Select-String 'Fatal:|Time:'
        "EXPECTED FAILURE: pin mutation $mutation rejected"
    }
} finally {Pop-Location}

