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
$graphics.Clear([Drawing.Color]::Transparent)

$background = New-Object Drawing.Drawing2D.GraphicsPath
$background.AddArc(8, 8, 44, 44, 180, 90)
$background.AddArc(204, 8, 44, 44, 270, 90)
$background.AddArc(204, 204, 44, 44, 0, 90)
$background.AddArc(8, 204, 44, 44, 90, 90)
$background.CloseFigure()
$backgroundBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 12, 13, 16))
$graphics.FillPath($backgroundBrush, $background)

$speedPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 255, 77, 68), 13)
$speedPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
$speedPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
$graphics.DrawLine($speedPen, 20, 74, 73, 74)
$graphics.DrawLine($speedPen, 32, 121, 73, 121)
$graphics.DrawLine($speedPen, 45, 168, 73, 168)

$cardPath = New-Object Drawing.Drawing2D.GraphicsPath
$cardPath.AddPolygon([Drawing.Point[]]@(
    (New-Object Drawing.Point(86, 26)),
    (New-Object Drawing.Point(172, 26)),
    (New-Object Drawing.Point(223, 77)),
    (New-Object Drawing.Point(223, 226)),
    (New-Object Drawing.Point(86, 226))
))
$cardBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 244, 242, 237))
$graphics.FillPath($cardBrush, $cardPath)

$foldPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 12, 13, 16), 8)
$graphics.DrawLine($foldPen, 172, 27, 172, 77)
$graphics.DrawLine($foldPen, 172, 77, 222, 77)

$markBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 255, 77, 68))
$graphics.FillRectangle($markBrush, 105, 77, 12, 79)

$contactBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 39, 41, 47))
for ($index = 0; $index -lt 5; $index++) {
    $graphics.FillRectangle($contactBrush, 125 + ($index * 17), 177, 9, 24)
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
    $background.Dispose()
    $backgroundBrush.Dispose()
    $speedPen.Dispose()
    $cardPath.Dispose()
    $cardBrush.Dispose()
    $foldPen.Dispose()
    $markBrush.Dispose()
    $contactBrush.Dispose()
}

Write-Output $OutputPath
