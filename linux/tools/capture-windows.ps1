<#
.SYNOPSIS
  Captures the Windows Media Shuttle client area so the Linux build can be diffed
  against it pixel for pixel.

.DESCRIPTION
  Runs the Debug build in --screenshot (visual preview) mode and renders the client
  area with PrintWindow, which works regardless of occlusion or which monitor the
  window is on. The result is a 1x PNG with no scaling, cropping or colour
  management.

  The window is left at the size the app chose for itself. Resizing it from a
  DPI-unaware shell gets the coordinates virtualised, so the canvas is measured
  from the capture instead of imposed on it.
#>
param(
    [string]$OutPath = "artifacts/ui-qa/windows-client.png",
    [int]$WaitSeconds = 6,
    [switch]$UseRunningInstance
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot "capture_client.cs") -ReferencedAssemblies System.Drawing

$exe = Join-Path $PSScriptRoot "..\..\windows\src\MediaShuttle\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\MediaShuttle.exe"
$exe = (Resolve-Path $exe).Path
if (-not (Test-Path $exe)) { throw "Debug build not found: $exe" }

$process = $null
try {
    if ($UseRunningInstance) {
        $process = Get-Process MediaShuttle -ErrorAction SilentlyContinue | Select-Object -First 1
    } else {
        $process = Start-Process -FilePath $exe -ArgumentList "--screenshot" -PassThru
    }
    if (-not $process) { throw "No Media Shuttle process. Build Debug first." }

    $title = "Media Shuttle — Visual Preview"
    $handle = [IntPtr]::Zero
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $handle = [Capture]::FindByTitle($title)
        if ($handle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($handle -eq [IntPtr]::Zero) { throw "Preview window not found: $title" }

    Start-Sleep -Seconds $WaitSeconds

    $dpi = [Capture]::GetDpiForWindow($handle)
    $bitmap = [Capture]::CaptureClient($handle)
    $root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $full = Join-Path $root $OutPath
    $directory = Split-Path $full -Parent
    if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $bitmap.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)

    $rect = New-Object Capture+RECT
    [Capture]::GetClientRect($handle, [ref] $rect) | Out-Null
    $clientW = $rect.Right - $rect.Left
    $clientH = $rect.Bottom - $rect.Top
    Write-Output "captured: $OutPath"
    Write-Output "client: $clientW x $clientH  dpi: $dpi  scale: $([math]::Round($dpi / 96.0, 3))"
}
finally {
    if (-not $UseRunningInstance -and $process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}
