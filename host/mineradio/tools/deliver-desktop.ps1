param([switch]$UpdateInterfaceOnly,[string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path (Split-Path $project -Parent) -Parent
$source = if ($PackageDirectory) { (Resolve-Path -LiteralPath $PackageDirectory).Path } else { Join-Path $project 'dist-fpga/win-unpacked' }
$evidence = Join-Path $workspace 'artifacts/fpgavedio_desktop_20261021'
$destination = 'C:/Users/hck/Desktop/FPGAvedio'
$linkPath = 'C:/Users/hck/Desktop/FPGAvedio.lnk'
if (!(Test-Path -LiteralPath (Join-Path $source 'FPGAvedio.exe'))) { throw '缺少已打包程序' }
$test = Get-Content -LiteralPath (Join-Path $evidence 'desktop-smoke.json') -Raw | ConvertFrom-Json
if (!$test.packagedApp -or $test.errors.Count -ne 0 -or $test.version.productName -ne 'FPGAvedio') { throw '桌面冒烟未通过' }
if ($UpdateInterfaceOnly) {
    if (!$test.dualMode -or !$test.modeStatePreserved -or !$test.narrowLayout -or !$test.mouseSwitch -or !$test.nativeWindowControls -or !$test.navigation -or $test.monitor.signal -ne 'true') { throw '桌面工作台验证未通过' }
    $installedExe = Join-Path $destination 'FPGAvedio.exe'
    if (!(Test-Path -LiteralPath $installedExe)) { throw '找不到桌面基线程序' }
    if ((Get-FileHash -LiteralPath $installedExe).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'FPGAvedio.exe')).Hash) { throw '桌面程序与已验证运行时不一致' }
    # Update application code only. No process termination or profile writes.
    $relativeFiles = @(
        'resources/app/public/fpga/desktop-integration.js',
        'resources/app/public/fpga/desktop-integration.css',
        'resources/app/public/fpga/embedded-workbench.css',
        'resources/app/public/fpga/desktop-workbench.js',
        'resources/app/desktop/instrument-bluetooth.js',
        'resources/app/desktop/instrument-serial.js',
        'resources/app/desktop/preload.js',
        'resources/app/desktop/main.js',
        'resources/app/public/instrument/src/app.js',
        'resources/app/public/instrument/src/transport.js',
        'resources/app/public/instrument/src/usb-transport.js',
        'resources/app/public/instrument/src/ble-transport.js',
        'resources/app/public/instrument/index.html',
        'resources/app/public/instrument/src/audio-arrangement.js',
        'resources/app/public/instrument/src/board-monitor.js',
        'resources/app/public/instrument/src/board-audio.js',
        'resources/app/public/instrument/src/board-audio-view.js',
        'resources/app/public/instrument/src/performance-protocol.js',
        'resources/app/public/instrument/src/performance-session.js',
        'resources/app/public/instrument/src/performance-view.js',
        'resources/app/public/instrument/src/score-upload.js',
        'resources/app/public/instrument/src/score-upload-protocol.js',
        'resources/app/public/instrument/src/fpga-score.js',
        'resources/app/public/instrument/src/device-session.js',
        'resources/app/public/instrument/src/score-library.js',
        'resources/app/public/instrument/src/audio.js',
        'resources/app/public/instrument/src/audio-worker.js',
        'resources/app/public/instrument/src/audio-dynamics.js',
        'resources/app/public/instrument/src/performance-monitor.js',
        'resources/app/public/instrument/styles.css',
        'resources/app/public/index.html',
        'resources/app/public/js/modules/05-playback/03a-home-dashboard.js',
        'resources/app/public/js/modules/00-state/08-desktop-render-power.js',
        'resources/app/public/js/modules/07-fx/03-wallpaper-engine-library.js',
        'resources/app/public/js/modules/10-shell/04-desktop-overlay-fullscreen.js',
        'resources/app/public/js/modules/10-shell/05-startup-bindings.js'
    )
    foreach ($relative in $relativeFiles) {
        if (!(Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "缺少更新文件: $relative" }
    }
    $backup = Join-Path $evidence ("interface-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($relative in $relativeFiles) {
        $target = Join-Path $destination $relative
        if (Test-Path -LiteralPath $target) {
            $backupFile = Join-Path $backup $relative
            New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $backupFile
        }
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target
        if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source $relative)).Hash) { throw "界面文件校验失败: $relative" }
    }
    $readme = Join-Path $destination '使用说明.txt'
    if (Test-Path -LiteralPath $readme) { Copy-Item -LiteralPath $readme -Destination $backup }
    Copy-Item -LiteralPath (Join-Path $evidence '使用说明.txt') -Destination $readme
    [pscustomobject]@{ directory = $destination; interfaceFiles = $relativeFiles; backup = $backup; verified = $true; restartRequired = $true } | ConvertTo-Json | Tee-Object -FilePath (Join-Path $evidence 'desktop-interface-delivery.json')
    exit 0
}
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $linkPath)) { throw '桌面目标已存在，停止以防覆盖' }
Copy-Item -LiteralPath $source -Destination $destination -Recurse
Copy-Item -LiteralPath (Join-Path $evidence '使用说明.txt') -Destination (Join-Path $destination '使用说明.txt')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($linkPath)
$shortcut.TargetPath = Join-Path $destination 'FPGAvedio.exe'
$shortcut.WorkingDirectory = $destination
$shortcut.IconLocation = "$(Join-Path $destination 'FPGAvedio.exe'),0"
$shortcut.Description = 'FPGAvedio · 音乐播放器与 FPGA BLE 曲谱工作台'
$shortcut.Save()
$sourceHash = (Get-FileHash -LiteralPath (Join-Path $source 'FPGAvedio.exe') -Algorithm SHA256).Hash
$desktopHash = (Get-FileHash -LiteralPath $shortcut.TargetPath -Algorithm SHA256).Hash
if ($sourceHash -ne $desktopHash) { throw '桌面程序校验失败' }
$sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File)
foreach ($file in $sourceFiles) {
    $relative = [IO.Path]::GetRelativePath($source, $file.FullName)
    $copied = Get-Item -LiteralPath (Join-Path $destination $relative)
    if ($copied.Length -ne $file.Length) { throw "复制尺寸异常: $relative" }
}
[pscustomobject]@{
    directory = $destination
    shortcut = $linkPath
    executable = $shortcut.TargetPath
    sha256 = $desktopHash
    filesChecked = $sourceFiles.Count
} | ConvertTo-Json | Tee-Object -FilePath (Join-Path $evidence 'desktop-delivery.json')
