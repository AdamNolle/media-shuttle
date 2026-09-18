[CmdletBinding()]
param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$distRoot = Join-Path $repoRoot 'dist'
$iconPath = Join-Path $repoRoot 'assets\MediaShuttle.ico'
$launcherSource = Join-Path $repoRoot 'src\Launcher\Program.cs'
$appSource = Join-Path $repoRoot 'src\App\Sony Media Shuttle.ps1'
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if ($Clean -and [IO.Directory]::Exists($distRoot)) {
    Get-ChildItem -LiteralPath $distRoot -File | Remove-Item -Force
}
if (-not [IO.Directory]::Exists($distRoot)) { [void][IO.Directory]::CreateDirectory($distRoot) }
if (-not [IO.File]::Exists($compiler)) { throw "Windows C# compiler not found at $compiler" }

& (Join-Path $repoRoot 'tools\New-Icon.ps1') -OutputPath $iconPath | Out-Null

$launcherOutput = Join-Path $distRoot 'MediaShuttle.exe'
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$iconPath" "/out:$launcherOutput" /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll $launcherSource
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE." }

Copy-Item -LiteralPath $appSource -Destination (Join-Path $distRoot 'Sony Media Shuttle.ps1') -Force
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $distRoot 'MediaShuttle.ico') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $distRoot 'README.md') -Force

Write-Output "Built $launcherOutput"

