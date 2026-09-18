[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Renders the Media Shuttle mark at each standard Windows icon size and packs them into one
# multi-resolution .ico. A single embedded 256px frame looks blurry once Windows downscales it
# for the taskbar/title bar (16-32px), so each tier below is drawn with size-appropriate detail
# rather than just shrinking the same artwork.
$sizes = 256, 128, 64, 48, 32, 24, 16

function New-MediaShuttleBitmap {
    param([int]$Size)

    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([Drawing.Color]::Transparent)

    $scale = $Size / 256.0
    $backgroundColor = [Drawing.Color]::FromArgb(255, 14, 15, 18)
    $cardColor = [Drawing.Color]::FromArgb(255, 244, 242, 237)
    $redColor = [Drawing.Color]::FromArgb(255, 255, 77, 68)
    $darkAccent = [Drawing.Color]::FromArgb(255, 32, 34, 39)

    # Rounded-square background, drawn slightly inset so the mark never touches the frame edge.
    $inset = 6 * $scale
    $corner = 56 * $scale
    $side = $Size - (2 * $inset)
    $bgRect = [Drawing.RectangleF]::new($inset, $inset, $side, $side)
    $background = [Drawing.Drawing2D.GraphicsPath]::new()
    $background.AddArc($bgRect.X, $bgRect.Y, $corner, $corner, 180, 90)
    $background.AddArc(($bgRect.Right - $corner), $bgRect.Y, $corner, $corner, 270, 90)
    $background.AddArc(($bgRect.Right - $corner), ($bgRect.Bottom - $corner), $corner, $corner, 0, 90)
    $background.AddArc($bgRect.X, ($bgRect.Bottom - $corner), $corner, $corner, 90, 90)
    $background.CloseFigure()
    $backgroundBrush = [Drawing.SolidBrush]::new($backgroundColor)
    $graphics.FillPath($backgroundBrush, $background)

    # The card: a light rectangle with a folded top-right corner, right of center.
    $cardPath = [Drawing.Drawing2D.GraphicsPath]::new()
    $points = [Drawing.PointF[]]@(
        [Drawing.PointF]::new((92 * $scale), (30 * $scale)),
        [Drawing.PointF]::new((168 * $scale), (30 * $scale)),
        [Drawing.PointF]::new((222 * $scale), (84 * $scale)),
        [Drawing.PointF]::new((222 * $scale), (222 * $scale)),
        [Drawing.PointF]::new((92 * $scale), (222 * $scale))
    )
    $cardPath.AddPolygon($points)
    $cardBrush = [Drawing.SolidBrush]::new($cardColor)
    $graphics.FillPath($cardBrush, $cardPath)

    if ($Size -ge 32) {
        $foldWidth = [Math]::Max(3.0, (7 * $scale))
        $foldPen = [Drawing.Pen]::new($darkAccent, $foldWidth)
        $foldPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $foldPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLine($foldPen, (168 * $scale), (31 * $scale), (168 * $scale), (84 * $scale))
        $graphics.DrawLine($foldPen, (168 * $scale), (84 * $scale), (221 * $scale), (84 * $scale))
        $foldPen.Dispose()
    }

    # Bold red accent mark along the card's left edge — the one element kept at every size.
    $markWidth = [Math]::Max(5.0, (14 * $scale))
    $markBrush = [Drawing.SolidBrush]::new($redColor)
    $graphics.FillRectangle($markBrush, (100 * $scale), (30 * $scale), $markWidth, (192 * $scale))

    if ($Size -ge 64) {
        # Full detail: three ascending "speed" bars left of the card, plus three bold contact pads.
        $speedPen = [Drawing.Pen]::new($redColor, (13 * $scale))
        $speedPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $speedPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLine($speedPen, (20 * $scale), (74 * $scale), (73 * $scale), (74 * $scale))
        $graphics.DrawLine($speedPen, (32 * $scale), (121 * $scale), (73 * $scale), (121 * $scale))
        $graphics.DrawLine($speedPen, (45 * $scale), (168 * $scale), (73 * $scale), (168 * $scale))
        $speedPen.Dispose()

        $contactBrush = [Drawing.SolidBrush]::new($darkAccent)
        $padWidth = 28 * $scale
        $padGap = 10 * $scale
        $padY = 178 * $scale
        $padHeight = 26 * $scale
        for ($index = 0; $index -lt 3; $index++) {
            $x = (128 * $scale) + ($index * ($padWidth + $padGap))
            $graphics.FillRectangle($contactBrush, $x, $padY, $padWidth, $padHeight)
        }
        $contactBrush.Dispose()
    }
    elseif ($Size -ge 32) {
        # Medium detail: a single simplified speed chevron and one contact pad — legible at 32-48px.
        $speedPen = [Drawing.Pen]::new($redColor, (16 * $scale))
        $speedPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $speedPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLine($speedPen, (26 * $scale), (100 * $scale), (72 * $scale), (100 * $scale))
        $speedPen.Dispose()

        $contactBrush = [Drawing.SolidBrush]::new($darkAccent)
        $graphics.FillRectangle($contactBrush, (130 * $scale), (178 * $scale), (72 * $scale), (28 * $scale))
        $contactBrush.Dispose()
    }
    # Below 32px: background + card + red accent only. Anything finer disappears into noise.

    $background.Dispose()
    $backgroundBrush.Dispose()
    $cardPath.Dispose()
    $cardBrush.Dispose()
    $markBrush.Dispose()
    $graphics.Dispose()
    return $bitmap
}

function ConvertTo-PngBytes {
    param([Drawing.Bitmap]$Bitmap)
    $stream = [IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not [IO.Directory]::Exists($outputDirectory)) {
    [void][IO.Directory]::CreateDirectory($outputDirectory)
}

$frames = [System.Collections.Generic.List[byte[]]]::new()
foreach ($size in $sizes) {
    $bitmap = New-MediaShuttleBitmap -Size $size
    $frames.Add((ConvertTo-PngBytes -Bitmap $bitmap))
    $bitmap.Dispose()
}

# Hand-write the .ico container (ICONDIR + ICONDIRENTRY[] + PNG-encoded frames). PNG frames are
# valid for every size on Windows Vista and later, and avoid the legacy BMP/AND-mask format.
$fileStream = [IO.FileStream]::new($OutputPath, [IO.FileMode]::Create)
$writer = [IO.BinaryWriter]::new($fileStream)
try {
    $writer.Write([uint16]0)       # reserved
    $writer.Write([uint16]1)       # type: icon
    $writer.Write([uint16]$sizes.Count)

    $offset = 6 + (16 * $sizes.Count)
    for ($index = 0; $index -lt $sizes.Count; $index++) {
        $size = $sizes[$index]
        $byteLength = $frames[$index].Length
        $dimensionByte = if ($size -ge 256) { 0 } else { $size }
        $writer.Write([byte]$dimensionByte)   # width (0 = 256)
        $writer.Write([byte]$dimensionByte)   # height (0 = 256)
        $writer.Write([byte]0)                # palette
        $writer.Write([byte]0)                # reserved
        $writer.Write([uint16]1)              # color planes
        $writer.Write([uint16]32)             # bits per pixel
        $writer.Write([uint32]$byteLength)
        $writer.Write([uint32]$offset)
        $offset += $byteLength
    }
    foreach ($frame in $frames) {
        $writer.Write($frame)
    }
}
finally {
    $writer.Dispose()
    $fileStream.Dispose()
}

Write-Output $OutputPath
