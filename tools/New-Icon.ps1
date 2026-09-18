[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('MediaShuttle.NativeIcon' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace MediaShuttle {
    public static class NativeIcon {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern bool DestroyIcon(IntPtr handle);
    }
}
'@
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not [IO.Directory]::Exists($outputDirectory)) {
    [void][IO.Directory]::CreateDirectory($outputDirectory)
}

$bitmap = New-Object Drawing.Bitmap(256, 256, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$graphics.Clear([Drawing.Color]::Transparent)

$shellPath = New-Object Drawing.Drawing2D.GraphicsPath
$shellPath.AddArc(8, 8, 44, 44, 180, 90)
$shellPath.AddArc(204, 8, 44, 44, 270, 90)
$shellPath.AddArc(204, 204, 44, 44, 0, 90)
$shellPath.AddArc(8, 204, 44, 44, 90, 90)
$shellPath.CloseFigure()
$shellBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 11, 12, 15))
$graphics.FillPath($shellBrush, $shellPath)

$cardPath = New-Object Drawing.Drawing2D.GraphicsPath
$cardPath.AddPolygon([Drawing.Point[]]@(
    (New-Object Drawing.Point(45, 32)),
    (New-Object Drawing.Point(168, 32)),
    (New-Object Drawing.Point(211, 75)),
    (New-Object Drawing.Point(211, 221)),
    (New-Object Drawing.Point(45, 221))
))
$cardBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 24, 26, 31))
$cardPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 93, 96, 105), 5)
$graphics.FillPath($cardBrush, $cardPath)
$graphics.DrawPath($cardPen, $cardPath)

$railBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 255, 59, 48))
$graphics.FillRectangle($railBrush, 58, 61, 9, 97)

$fontFamily = New-Object Drawing.FontFamily('Segoe UI')
$cfFont = New-Object Drawing.Font($fontFamily, 62, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$labelFont = New-Object Drawing.Font($fontFamily, 20, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$whiteBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 244, 242, 237))
$mutedBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 174, 176, 184))
$graphics.DrawString('CF', $cfFont, $whiteBrush, 75, 66)
$graphics.DrawString('MEDIA', $labelFont, $mutedBrush, 77, 137)

$contactBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 92, 95, 104))
for ($index = 0; $index -lt 6; $index++) {
    $graphics.FillRectangle($contactBrush, 76 + ($index * 18), 181, 10, 20)
}

$iconHandle = $bitmap.GetHicon()
$icon = [Drawing.Icon]::FromHandle($iconHandle)
$stream = New-Object IO.FileStream($OutputPath, [IO.FileMode]::Create)
try {
    $icon.Save($stream)
}
finally {
    $stream.Dispose()
    $icon.Dispose()
    [void][MediaShuttle.NativeIcon]::DestroyIcon($iconHandle)
    $graphics.Dispose()
    $bitmap.Dispose()
    $shellPath.Dispose()
    $shellBrush.Dispose()
    $cardPath.Dispose()
    $cardBrush.Dispose()
    $cardPen.Dispose()
    $railBrush.Dispose()
    $fontFamily.Dispose()
    $cfFont.Dispose()
    $labelFont.Dispose()
    $whiteBrush.Dispose()
    $mutedBrush.Dispose()
    $contactBrush.Dispose()
}

Write-Output $OutputPath

