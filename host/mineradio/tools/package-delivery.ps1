$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$workspace = (Resolve-Path (Join-Path $project '../..')).Path
$delivery = Join-Path $workspace 'artifacts/mineradio_app_20261020'
$apk = Join-Path $project 'android/build/xingzhewujiang-mineradio-v3.apk'
$tools = Join-Path $workspace 'work/android_toolchain_20261020'
$java = Join-Path $tools 'jdk/jdk-17.0.20.1+1/bin/java.exe'
$sdk = Join-Path $tools 'build-tools/android-14'
New-Item -ItemType Directory -Path $delivery -Force | Out-Null
& "$sdk/zipalign.exe" -c 4 $apk
if ($LASTEXITCODE -ne 0) { throw 'APK alignment failed' }
$signature = & $java -jar "$sdk/lib/apksigner.jar" verify --verbose --print-certs $apk
if ($LASTEXITCODE -ne 0) { throw 'APK signature failed' }
$manifest = & "$sdk/aapt2.exe" dump badging $apk
if ($LASTEXITCODE -ne 0) { throw 'APK manifest failed' }
Add-Type -AssemblyName System.IO.Compression
$archive = [IO.Compression.ZipFile]::OpenRead($apk)
try {
    if (@($archive.Entries | Where-Object { $_.FullName.Contains('\') }).Count) { throw 'Non-Android ZIP paths' }
    foreach ($name in @('assets/mobile.html', 'assets/fpga/mobile.js', 'assets/instrument/src/app.js', 'assets/instrument/model/model.json', 'assets/instrument/model/group1-shard1of1.bin', 'assets/instrument/wasm/tfjs-backend-wasm.wasm', 'assets/instrument/licenses.txt', 'assets/NOTICE.md', 'classes.dex')) {
        if (-not $archive.GetEntry($name)) { throw "Missing APK entry: $name" }
    }
    # Assert that the exact verified page sources are the ones inside the APK.
    foreach ($name in @('mobile.html', 'fpga/mobile.js', 'fpga/native-rpc.js', 'instrument/src/app.js', 'instrument/src/native-ble-transport.js', 'instrument/src/audio-arrangement.js', 'NOTICE.md')) {
        $stream = $archive.GetEntry("assets/$name").Open()
        $digest = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($digest.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $digest.Dispose() }
        $expected = (Get-FileHash (Join-Path $project "android/app/src/main/assets/$name") -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "Stale APK asset: $name" }
    }
} finally { $archive.Dispose() }
Copy-Item -LiteralPath $apk -Destination $delivery
Copy-Item -LiteralPath (Join-Path $project 'README-FPGA.md') -Destination (Join-Path $delivery '使用说明.md')
[IO.File]::WriteAllLines((Join-Path $delivery 'apk-signature.txt'), [string[]]$signature)
[IO.File]::WriteAllLines((Join-Path $delivery 'apk-manifest.txt'), [string[]]$manifest)

# Corresponding source, retaining the complete upstream fork and shared host.
# Build outputs and private signing keys are deliberately excluded.
$sourceZip = Join-Path $delivery 'mineradio-fpga-source.zip'
$zipStream = [IO.File]::Open($sourceZip, [IO.FileMode]::Create)
$source = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($folder in @('host/mineradio', 'host/instrument-web')) {
        $base = Join-Path $workspace $folder
        foreach ($file in Get-ChildItem -LiteralPath $base -Recurse -File) {
            $relative = [IO.Path]::GetRelativePath($base, $file.FullName).Replace('\', '/')
            if ($relative -match '(^|/)(node_modules|\.git|evidence|dist)(/|$)' -or $relative -match '^android/(build|signing|app/src/main/assets)/' -or $relative -match '^public/instrument/' -or $relative -match '\.(keystore|log)$') { continue }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($source, $file.FullName, "$folder/$relative", [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
} finally { $source.Dispose(); $zipStream.Dispose() }
$hashes = foreach ($name in @('xingzhewujiang-mineradio-v3.apk', 'mineradio-fpga-source.zip')) {
    $hash = Get-FileHash (Join-Path $delivery $name) -Algorithm SHA256
    "$($hash.Hash)  $name"
}
[IO.File]::WriteAllLines((Join-Path $delivery 'SHA256SUMS.txt'), [string[]]$hashes)
$hashes
Write-Host "Verified delivery: $delivery"
