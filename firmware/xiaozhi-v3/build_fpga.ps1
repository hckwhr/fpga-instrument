param([string]$BuildRoot = 'E:/Gowin/workspace/xiaozhi_fpga_20261022')
$ErrorActionPreference = 'Stop'
# Isolated ASCII tree, retaining the relative shared BLE component path.
$repo = $PSScriptRoot
$fwRoot = Split-Path $repo -Parent
New-Item -ItemType Directory -Path "$BuildRoot/xiaozhi-v3","$BuildRoot/esp32s3-bridge/main" -Force | Out-Null
robocopy $repo "$BuildRoot/xiaozhi-v3" /E /XD .git build managed_components /XF sdkconfig sdkconfig.old dependencies.lock | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Source copy failed' }
Copy-Item "$fwRoot/esp32s3-bridge/main/*" "$BuildRoot/esp32s3-bridge/main" -Force
$env:IDF_PATH = 'D:/espidf5.44/v5.4.4/esp-idf'
$env:IDF_TOOLS_PATH = 'C:/Espressif/tools'
$env:IDF_PYTHON_ENV_PATH = 'C:/Espressif/tools/python/v5.4.4/venv'
$env:IDF_TARGET = 'esp32s3'
$env:Path = 'E:/Arduino/data/packages/esp32/tools/esp-x32/2601/bin;C:/Espressif/tools/cmake/3.30.2/bin;C:/Espressif/tools/ninja/1.12.1;' + $env:Path
$env:PYTHONUTF8 = '1'
$project = "$BuildRoot/xiaozhi-v3"
# Generate the board-specific defaults from its single authoritative config.json.
$variant = Get-Content "$repo/main/boards/fpga-bread-s3/config.json" -Raw | ConvertFrom-Json
$defaults = @('CONFIG_BOARD_TYPE_FPGA_BREAD_S3=y') + $variant.builds[0].sdkconfig_append
$defaults | Set-Content "$project/fpga.defaults" -Encoding utf8NoBOM
Push-Location $project
try {
    $log = "$BuildRoot/build_$(Get-Date -Format yyyyMMdd_HHmmss).log"
    & "$env:IDF_PYTHON_ENV_PATH/Scripts/python.exe" "$env:IDF_PATH/tools/idf.py" -B build -D 'SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.defaults.esp32s3;fpga.defaults' build *> $log
    $buildExit = $LASTEXITCODE
    Get-Content $log -Tail 60
    if ($buildExit -ne 0) { throw "Build failed; see $log" }
} finally { Pop-Location }
