param(
    [string]$BuildRoot = 'E:/Gowin/workspace/esp32s3_bridge_stage48_20261014',
    [string]$ArchiveRoot = "$PSScriptRoot/../../artifacts/esp32s3_bridge_stage48_20261014"
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$inputs = @('CMakeLists.txt', 'sdkconfig.defaults', 'main/CMakeLists.txt', 'main/board.h',
    'main/bridge_core.h', 'main/bridge_core.c', 'main/main.c')
$image = Get-Item -LiteralPath "$BuildRoot/build_verified/instrument_bridge.bin"
foreach ($relative in $inputs) {
    $source = Join-Path $sourceRoot $relative
    $copied = Join-Path $BuildRoot $relative
    if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $copied).Hash) {
        throw "Source/build mismatch: $relative"
    }
    if ((Get-Item -LiteralPath $copied).LastWriteTimeUtc -gt $image.LastWriteTimeUtc) {
        throw "Build input newer than image: $relative"
    }
}
$config = Get-Content -LiteralPath "$BuildRoot/sdkconfig" -Raw
if ($config -notmatch 'CONFIG_IDF_TARGET="esp32s3"' -or
    $config -notmatch 'CONFIG_ESPTOOLPY_FLASHSIZE="16MB"' -or
    $config -notmatch 'CONFIG_BT_NIMBLE_ENABLED=y') { throw 'Wrong firmware configuration' }
$log = Get-Content -LiteralPath "$BuildRoot/build_verified.log" -Raw
if ($log -notmatch 'Project build complete\.' -or $log -match '\berror:') { throw 'No clean final build log' }

New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null
$files = @('build_verified/instrument_bridge.bin', 'build_verified/instrument_bridge.elf',
    'build_verified/instrument_bridge.map', 'build_verified/bootloader/bootloader.bin',
    'build_verified/partition_table/partition-table.bin', 'build_verified/flasher_args.json',
    'build_verified/flash_args', 'build_verified/project_description.json',
    'sdkconfig', 'build_verified.log', 'configure_verified.log', 'configure.log')
foreach ($relative in $files) {
    $destination = Join-Path $ArchiveRoot $relative
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $BuildRoot $relative) -Destination $destination -Force
}
# Preserve the original missing-library failure; do not replace it with success.
Copy-Item -LiteralPath "$BuildRoot/build/log/idf_py_stderr_output_42408" -Destination "$ArchiveRoot/initial_toolchain_failure.log" -Force
Copy-Item -LiteralPath "$sourceRoot/build-host/Testing/Temporary/LastTest.log" -Destination "$ArchiveRoot/core_scenarios.log" -Force
$sources = @($inputs) + @('pinmap.json', 'README.md', 'archive.ps1',
    'tests/CMakeLists.txt', 'tests/test_bridge.c', 'tests/run.py', 'tests/protocol-roundtrip.mjs')
foreach ($relative in $sources) {
    $destination = Join-Path "$ArchiveRoot/source" $relative
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination -Force
}
$ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).Path
$hashes = Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse |
    Where-Object Name -ne 'sha256.json' | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            file = [IO.Path]::GetRelativePath($ArchiveRoot, $_.FullName).Replace('\', '/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
$hashes | ConvertTo-Json -Depth 4 | Out-File -LiteralPath "$ArchiveRoot/sha256.json" -Encoding utf8
Write-Output "Archived $($hashes.Count) files; seven build inputs match source; image timestamp checked."
Get-FileHash -LiteralPath "$ArchiveRoot/build_verified/instrument_bridge.bin" -Algorithm SHA256 | Format-List
