[CmdletBinding()]
param(
    [switch]$EnableStartup
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$publishRoot = Join-Path $repoRoot 'artifacts\publish\win-x64'
$cameraRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Camera'
$installRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Media Shuttle'
$expectedInstallRoot = 'C:\Users\' + [Environment]::UserName + '\AppData\Local\Programs\Media Shuttle'

& (Join-Path $repoRoot 'build.ps1') -Clean

foreach ($directory in @(
    $cameraRoot,
    (Join-Path $cameraRoot 'Photos\JPEGs'),
    (Join-Path $cameraRoot 'Photos\RAWs'),
    (Join-Path $cameraRoot 'Photos\Other'),
    (Join-Path $cameraRoot 'Videos')
)) {
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
}

$resolvedInstallRoot = [IO.Path]::GetFullPath($installRoot)
if ($resolvedInstallRoot -ne [IO.Path]::GetFullPath($expectedInstallRoot)) {
    throw 'The application install path did not resolve to the expected per-user location.'
}

Get-Process -Name 'MediaShuttle' -ErrorAction SilentlyContinue | Stop-Process -Force
if ([IO.Directory]::Exists($installRoot)) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Get-ChildItem -LiteralPath $publishRoot -Force | Copy-Item -Destination $installRoot -Recurse -Force

$shell = New-Object -ComObject WScript.Shell
$executable = Join-Path $installRoot 'MediaShuttle.exe'

function New-MediaShuttleShortcut([string]$Path, [string]$Arguments) {
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $executable
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = 'Open Media Shuttle'
    $shortcut.IconLocation = $executable
    $shortcut.Save()
}

New-MediaShuttleShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Media Shuttle.lnk') ''
New-MediaShuttleShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'Media Shuttle.lnk') ''

$legacyStartup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Sony Media Shuttle.lnk'
if (Test-Path -LiteralPath $legacyStartup) { Remove-Item -LiteralPath $legacyStartup -Force }
if ($EnableStartup) {
    New-MediaShuttleShortcut (Join-Path ([Environment]::GetFolderPath('Startup')) 'Media Shuttle.lnk') '--background'
}

Start-Process -FilePath $executable
Write-Output "Installed Media Shuttle to $installRoot"
