param([switch]$SkipAssets)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$workspace = (Resolve-Path (Join-Path $project '../..')).Path
$toolchain = Join-Path $workspace 'work/android_toolchain_20261020'
$jdk = Join-Path $toolchain 'jdk/jdk-17.0.20.1+1'
$sdkTools = Join-Path $toolchain 'build-tools/android-14'
$androidJar = Join-Path $toolchain 'platform/android-34/android.jar'
$output = Join-Path $PSScriptRoot 'build'
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)" }
}
if (-not $SkipAssets) {
    Push-Location (Join-Path $project '../instrument-web')
    try { Invoke-Checked 'npm.cmd' @('run', 'build') } finally { Pop-Location }
    Invoke-Checked 'node' @((Join-Path $project 'tools/prepare-app.mjs'))
}
Push-Location $PSScriptRoot
try {
# aapt2 on Windows cannot open non-ASCII absolute resource paths. All its
# arguments stay relative to this directory; no external build folder is needed.
$output = 'build'
$androidJar = (Resolve-Path -Relative $androidJar)
foreach ($folder in @($output, "$output/generated", "$output/classes", "$output/dex")) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}
$main = 'app/src/main'
Invoke-Checked "$sdkTools/aapt2.exe" @('compile', '--dir', "$main/res", '-o', "$output/resources.zip")
Invoke-Checked "$sdkTools/aapt2.exe" @('link', '-o', "$output/unsigned.apk", '-I', $androidJar, '--manifest', "$main/AndroidManifest.xml", '-A', "$main/assets", '--java', "$output/generated", '--version-code', '106', '--version-name', '1.2.0', '--min-sdk-version', '26', '--target-sdk-version', '34', "$output/resources.zip")
$sources = @(Get-ChildItem "$main/java", "$output/generated" -Filter '*.java' -File -Recurse | ForEach-Object FullName)
Invoke-Checked "$jdk/bin/javac.exe" (@('-encoding', 'UTF-8', '-source', '8', '-target', '8', '-classpath', $androidJar, '-d', "$output/classes") + $sources)
Invoke-Checked "$jdk/bin/jar.exe" @('cf', "$output/classes.jar", '-C', "$output/classes", '.')
Invoke-Checked "$jdk/bin/java.exe" @('-cp', "$sdkTools/lib/d8.jar", 'com.android.tools.r8.D8', '--lib', $androidJar, '--min-api', '26', '--output', "$output/dex", "$output/classes.jar")
Invoke-Checked "$jdk/bin/jar.exe" @('uf', "$output/unsigned.apk", '-C', "$output/dex", 'classes.dex')
# This Windows aapt2 writes backslashes inside nested asset ZIP entries. Android
# AssetManager requires forward slashes. Normalize before alignment/signing.
Add-Type -AssemblyName System.IO.Compression
$archive = [IO.Compression.ZipFile]::Open((Join-Path $PSScriptRoot "$output/unsigned.apk"), [IO.Compression.ZipArchiveMode]::Update)
try {
    foreach ($entry in @($archive.Entries | Where-Object { $_.FullName.Contains('\') })) {
        $name = $entry.FullName.Replace('\', '/')
        $buffer = [IO.MemoryStream]::new()
        $stream = $entry.Open()
        try { $stream.CopyTo($buffer) } finally { $stream.Dispose() }
        $entry.Delete()
        $replacement = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $stream = $replacement.Open()
        try { $buffer.Position = 0; $buffer.CopyTo($stream) } finally { $stream.Dispose(); $buffer.Dispose() }
    }
    foreach ($name in @('assets/android.html', 'assets/js/index-loader.js', 'assets/fpga/android-player.js', 'assets/instrument/src/app.js', 'assets/instrument/model/model.json', 'assets/instrument/wasm/tfjs-backend-wasm.wasm', 'classes.dex')) {
        if (-not $archive.GetEntry($name)) { throw "APK is missing $name" }
    }
} finally { $archive.Dispose() }
Invoke-Checked "$sdkTools/zipalign.exe" @('-f', '4', "$output/unsigned.apk", "$output/aligned.apk")
$signing = Join-Path $PSScriptRoot 'signing'
New-Item -ItemType Directory -Path $signing -Force | Out-Null
$key = Join-Path $signing 'demo.keystore'
# Local demonstration identity, deliberately separate from any release key.
if (-not (Test-Path $key)) {
    Invoke-Checked "$jdk/bin/keytool.exe" @('-genkeypair', '-keystore', $key, '-storepass', 'android', '-keypass', 'android', '-alias', 'mineradio-demo', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000', '-dname', 'CN=Mineradio FPGA Demo,O=Xingzhewujiang,C=CN')
}
$apk = Join-Path $output 'FPGAvedio-Android.apk'
Invoke-Checked "$jdk/bin/java.exe" @('-jar', "$sdkTools/lib/apksigner.jar", 'sign', '--ks', $key, '--ks-key-alias', 'mineradio-demo', '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', $apk, "$output/aligned.apk")
Invoke-Checked "$jdk/bin/java.exe" @('-jar', "$sdkTools/lib/apksigner.jar", 'verify', '--verbose', '--print-certs', $apk)
Get-FileHash -LiteralPath $apk -Algorithm SHA256
Write-Host "APK: $apk"
} finally { Pop-Location }
