param([string]$BuildRoot='E:/Gowin/workspace/v3_full_stage54j_20261017')
$ErrorActionPreference='Stop'
Push-Location $BuildRoot
try {
    $result=& E:/modelsim/win64/vsim.exe -c work.tb_menu_delay_contract -gMUTATION=1 -l sim/menu_delay_negative.transcript -wlf sim/menu_delay_negative.wlf -do 'run -all; quit -f' 2>&1
    $result | Set-Content sim/menu_delay_negative.log -Encoding utf8
    if(!($result -match '# \*\* Fatal: MENU_DELAY_UNSAFE: receiver enable differs') -or ($result -match '# PASS:')){
        throw 'Removing menu mask was not detected'
    }
    'EXPECTED FAILURE: missing menu mask detected'
} finally {Pop-Location}
