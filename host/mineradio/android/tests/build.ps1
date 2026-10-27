$ErrorActionPreference = 'Stop'
$toolchain = (Resolve-Path "$PSScriptRoot/../../../../work/android_toolchain_20261020").Path
$jdk = Join-Path $toolchain 'jdk/jdk-17.0.20.1+1'
$sdk = Join-Path $toolchain 'build-tools/android-14'
$jar = Join-Path $toolchain 'platform/android-34/android.jar'
function Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed: $LASTEXITCODE" }
}
Push-Location $PSScriptRoot
try {
    foreach ($path in @('../build/device-test/classes','../build/device-test/dex')) { New-Item -ItemType Directory -Force $path | Out-Null }
    $jar = Resolve-Path -Relative $jar
    Checked "$sdk/aapt2.exe" @('link','-o','../build/device-test/unsigned.apk','-I',$jar,'--manifest','AndroidManifest.xml')
    Checked "$jdk/bin/javac.exe" @('-encoding','UTF-8','-source','8','-target','8','-classpath',$jar,'-d','../build/device-test/classes','PlaybackInstrumentation.java')
    Checked "$jdk/bin/jar.exe" @('cf','../build/device-test/classes.jar','-C','../build/device-test/classes','.')
    Checked "$jdk/bin/java.exe" @('-cp',"$sdk/lib/d8.jar",'com.android.tools.r8.D8','--lib',$jar,'--min-api','26','--output','../build/device-test/dex','../build/device-test/classes.jar')
    Checked "$jdk/bin/jar.exe" @('uf','../build/device-test/unsigned.apk','-C','../build/device-test/dex','classes.dex')
    Checked "$sdk/zipalign.exe" @('-f','4','../build/device-test/unsigned.apk','../build/device-test/aligned.apk')
    Checked "$jdk/bin/java.exe" @('-jar',"$sdk/lib/apksigner.jar",'sign','--ks','../signing/demo.keystore','--ks-key-alias','mineradio-demo','--ks-pass','pass:android','--key-pass','pass:android','--out','../build/device-test/playback-test.apk','../build/device-test/aligned.apk')
} finally { Pop-Location }
