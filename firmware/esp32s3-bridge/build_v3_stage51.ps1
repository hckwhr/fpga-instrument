$ErrorActionPreference='Stop'
$source=$PSScriptRoot
$target='E:/Gowin/workspace/esp32s3_bridge_stage51_20261015'
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -LiteralPath "$source/main" -Destination $target -Recurse -Force
foreach($name in @('CMakeLists.txt','sdkconfig.defaults')){
    Copy-Item -LiteralPath "$source/$name" -Destination $target -Force
}
$env:IDF_PATH='D:/espidf5.44/v5.4.4/esp-idf'
$env:IDF_TOOLS_PATH='C:/Espressif/tools'
$env:IDF_PYTHON_ENV_PATH='C:/Espressif/tools/python/v5.4.4/venv'
$env:Path='E:/Arduino/data/packages/esp32/tools/esp-x32/2601/bin;C:/Espressif/tools/cmake/3.30.2/bin;C:/Espressif/tools/ninja/1.12.1;'+$env:Path
Push-Location $target
try{
    if(Test-Path build_verified.log){Copy-Item -LiteralPath build_verified.log -Destination ('build_verified_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.log')}
    & 'C:/Espressif/tools/python/v5.4.4/venv/Scripts/python.exe' "$env:IDF_PATH/tools/idf.py" -B build_verified build *> build_verified.log
    if($LASTEXITCODE -ne 0){throw 'V3 S3 build failed; see build_verified.log'}
}finally{Get-Content build_verified.log -Tail 35;Pop-Location}
