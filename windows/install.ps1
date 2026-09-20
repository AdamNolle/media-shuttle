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

& (Join-Path $repoRoot 'build.ps1') -Clean -SkipInstaller

# The destination root only. The category folders belong to a transfer, which creates the
# ones it actually has files for — scaffolding all four here put empty Photos\Other and
# Videos folders in a destination nothing had been copied to yet.
if (-not [IO.Directory]::Exists($cameraRoot)) { [void][IO.Directory]::CreateDirectory($cameraRoot) }

$resolvedInstallRoot = [IO.Path]::GetFullPath($installRoot)
if ($resolvedInstallRoot -ne [IO.Path]::GetFullPath($expectedInstallRoot)) {
    throw 'The application install path did not resolve to the expected per-user location.'
}

# Stop-Process returns as soon as the kill is requested, not once Windows has released
# the process's file handles. Replacing the install directory before that happens fails
# part-way through on a locked runtime DLL and leaves the previous install gutted.
foreach ($process in @(Get-Process -Name 'MediaShuttle' -ErrorAction SilentlyContinue)) {
    $process | Stop-Process -Force
    if (-not $process.WaitForExit(15000)) {
        throw 'Media Shuttle is still running and could not be closed. Close it and try again.'
    }
}

if ([IO.Directory]::Exists($installRoot)) {
    $removed = $false
    foreach ($attempt in 1..10) {
        try {
            Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
            $removed = $true
            break
        }
        catch [UnauthorizedAccessException], [IO.IOException] {
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
    if (-not $removed) {
        throw "Could not replace $installRoot. Something still has a file in it open."
    }
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
