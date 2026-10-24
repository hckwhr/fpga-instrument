$ErrorActionPreference='Stop'
$baseline='E:/Gowin/workspace/xiaozhi_fpga_20261022/xiaozhi-v3'
$candidate='E:/Gowin/workspace/xiaozhi_uart_stage64_20261023'
$project=Join-Path $candidate 'xiaozhi-v3'
New-Item -ItemType Directory -Path $project -Force | Out-Null
# Reuse locally resolved dependencies and exact board/target configuration.
# No baseline build directory, NVS image, or hardware contents are modified.
if (!(Test-Path "$project/managed_components")) {
    Copy-Item -LiteralPath "$baseline/managed_components" -Destination $project -Recurse
}
foreach($name in @('sdkconfig','dependencies.lock')) {
    if (!(Test-Path "$project/$name")) { Copy-Item -LiteralPath "$baseline/$name" -Destination $project }
}
Remove-Item Env:MSYSTEM,Env:MSYS2_PATH -ErrorAction SilentlyContinue
$started=Get-Date
& "$PSScriptRoot/build_fpga.ps1" -BuildRoot $candidate
$image=Get-Item "$project/build/xiaozhi.bin" -ErrorAction Stop
if($image.LastWriteTime -lt $started){throw 'No fresh ESP32 image was built'}
& 'C:/Espressif/tools/python/v5.4.4/venv/Scripts/python.exe' 'C:/Users/hck/.agents/skills/build-idf/scripts/idf_builder.py' --scan-artifacts "$project/build" --no-save-profile
if($LASTEXITCODE -ne 0){throw 'IDF artifact scan failed'}
