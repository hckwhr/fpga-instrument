param([string]$ModelSimBin='E:/modelsim/win64',
      [string]$PrimitiveFile='E:/Gowin/Gowin_V1.9.12.03_x64/IDE/simlib/gw5a/prim_sim.v')
$ErrorActionPreference='Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    # Separate library: existing audio benches intentionally contain primitive stubs.
    if(!(Test-Path hdmi_phy_work)){& "$ModelSimBin/vlib.exe" hdmi_phy_work}
    # PLL outputs use independent real-valued delay loops. At 1 ps precision,
    # rounding 371.25/74.25 MHz half-periods causes artificial phase drift. Keep the
    # vendor source intact and simulate all modules at 1 fs precision.
    & "$ModelSimBin/vlog.exe" -override_timescale '1ns/1fs' -work hdmi_phy_work $PrimitiveFile src/pll_init.v rtl/hdmi_pll/hdmi_pll_mod.v rtl/hdmi_pll/hdmi_pll.v rtl/hdmi_clocks.v rtl/tmds_encoder.v rtl/hdmi_tmds_tx.v sim/tb_hdmi_serializer.sv sim/tb_hdmi_clock_startup.sv sim/tb_hdmi_startup_contract.sv
    if($LASTEXITCODE -ne 0){throw 'HDMI PHY compilation failed'}
    $result=& "$ModelSimBin/vsim.exe" -t 1fs -c hdmi_phy_work.tb_hdmi_serializer -do 'run -all; quit -f' 2>&1
    $code=$LASTEXITCODE
    $result | Tee-Object -FilePath sim/tb_hdmi_serializer.log
    if($code -ne 0 -or !($result -match '# PASS:') -or ($result -match '# \*\* (Error|Fatal):')){throw 'HDMI PHY simulation failed'}
    $result=& "$ModelSimBin/vsim.exe" -t 1fs -c hdmi_phy_work.tb_hdmi_clock_startup -do 'run -all; quit -f' 2>&1
    $code=$LASTEXITCODE
    $result | Tee-Object -FilePath sim/tb_hdmi_clock_startup.log
    if($code -ne 0 -or !($result -match '# PASS:') -or ($result -match '# \*\* (Error|Fatal):')){throw 'Production HDMI PLL startup failed'}
    $result=& "$ModelSimBin/vsim.exe" -t 1fs -c hdmi_phy_work.tb_hdmi_startup_contract -do 'run -all; quit -f' 2>&1
    $code=$LASTEXITCODE
    $result | Tee-Object -FilePath sim/tb_hdmi_startup_contract.log
    if($code -ne 0 -or !($result -match '# PASS:') -or ($result -match '# \*\* (Error|Fatal):')){throw 'Quiet-clock reset contract failed'}
} finally {Pop-Location}
