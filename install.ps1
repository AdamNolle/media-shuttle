[CmdletBinding()]
param(
    [switch]$EnableStartup
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$distRoot = Join-Path $repoRoot 'dist'
$cameraRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Camera'
$installRoot = Join-Path $cameraRoot 'Sony Media Shuttle'

& (Join-Path $repoRoot 'build.ps1') -Clean

foreach ($directory in @(
    $cameraRoot,
    $installRoot,
    (Join-Path $cameraRoot 'Photos\JPEGs'),
    (Join-Path $cameraRoot 'Photos\RAWs'),
    (Join-Path $cameraRoot 'Videos')
)) {
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
}

foreach ($fileName in @('MediaShuttle.exe', 'MediaShuttle.ico', 'Sony Media Shuttle.ps1', 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $distRoot $fileName) -Destination (Join-Path $installRoot $fileName) -Force
}

$shell = New-Object -ComObject WScript.Shell
$launcherPath = Join-Path $installRoot 'MediaShuttle.exe'
$iconPath = Join-Path $installRoot 'MediaShuttle.ico'

function New-MediaShuttleShortcut([string]$Path, [string]$Arguments) {
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $launcherPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = 'Open Media Shuttle'
    $shortcut.IconLocation = $iconPath
    $shortcut.Save()
}

New-MediaShuttleShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Media Shuttle.lnk') ''
New-MediaShuttleShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'Media Shuttle.lnk') ''

if ($EnableStartup) {
    New-MediaShuttleShortcut (Join-Path ([Environment]::GetFolderPath('Startup')) 'Sony Media Shuttle.lnk') '--background'
}

Write-Output "Installed Media Shuttle to $installRoot"

