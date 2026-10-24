$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$evidence = Join-Path $PSScriptRoot '../evidence'
function Add-ReviewNotes($inputFile, $outputFile, $title, $notes, $color) {
    $source = [System.Drawing.Image]::FromFile((Join-Path $evidence $inputFile))
    $output = [System.Drawing.Bitmap]::new($source.Width, $source.Height + 100)
    $graphics = [System.Drawing.Graphics]::FromImage($output)
    $font = [System.Drawing.Font]::new('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Regular)
    $smallFont = [System.Drawing.Font]::new('Microsoft YaHei', 12)
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($color))
    $pen = [System.Drawing.Pen]::new($brush, 3)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(255, 250, 245))
        $graphics.DrawImageUnscaled($source, 0, 100)
        $graphics.DrawString($title, $font, $brush, 22, 15)
        $graphics.DrawString('编号与 UI_DESIGN.md 对应；框线为评审叠加，原始截图未改动。', $smallFont, $brush, 22, 57)
        foreach ($note in $notes) {
            $y = [int]$note.Y + 100
            $graphics.DrawRectangle($pen, [int]$note.X, $y, [int]$note.W, [int]$note.H)
            $graphics.FillRectangle([System.Drawing.Brushes]::White, [int]$note.X + 4, $y + 4, [int]$note.W - 8, 30)
            $graphics.DrawString($note.Text, $smallFont, $brush, [int]$note.X + 9, $y + 7)
        }
        $output.Save((Join-Path $evidence $outputFile), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $pen.Dispose(); $brush.Dispose(); $font.Dispose(); $smallFont.Dispose(); $graphics.Dispose(); $output.Dispose(); $source.Dispose()
    }
}
Add-ReviewNotes 'ui-before.png' 'ui-review-before.png' '原版：需要调整的信息层级与视觉系统' @(
    @{X=70;Y=190;W=1125;H=450;Text='I1 · P1  通信测试占据首屏，音乐导入被推到下方'},
    @{X=70;Y=660;W=1125;H=292;Text='V1 · P1  深蓝、荧光色与用户希望的柔和暖色不符'},
    @{X=70;Y=970;W=1125;H=414;Text='I2 · P1  设置与试听分散，完成同一次转谱需要上下寻找'}
) '#9d3630'
Add-ReviewNotes 'audio-desktop.png' 'ui-review-after.png' '优化方向与复评：暖色、左侧输入、右侧结果' @(
    @{X=78;Y=223;W=392;H=715;Text='V1 / I2 已解决：统一暖色，导入与识别同区'},
    @{X=496;Y=223;W=705;H=820;Text='I2 已解决：预览、试听、调整、导出集中'},
    @{X=78;Y=1064;W=1124;H=62;Text='I1 已解决：设备功能收起，按需展开'}
) '#43634d'
