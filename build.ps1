[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$project = Join-Path $repoRoot 'src\MediaShuttle\MediaShuttle.csproj'
$tests = Join-Path $repoRoot 'tests\MediaShuttle.Core.Tests\MediaShuttle.Core.Tests.csproj'
$artifacts = Join-Path $repoRoot 'artifacts'
$publishRoot = Join-Path $artifacts 'publish\win-x64'
$buildOutput = Join-Path $repoRoot 'src\MediaShuttle\bin\Release\net8.0-windows10.0.19041.0\win-x64'
$iconPath = Join-Path $repoRoot 'src\MediaShuttle\Assets\MediaShuttle.ico'
$releaseZip = Join-Path $artifacts 'MediaShuttle-v2.0.0-win-x64.zip'

if ($Clean -and [IO.Directory]::Exists($artifacts)) {
    Remove-Item -LiteralPath $artifacts -Recurse -Force
}
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null

& (Join-Path $repoRoot 'tools\New-Icon.ps1') -OutputPath $iconPath | Out-Null

dotnet restore $project
if ($LASTEXITCODE -ne 0) { throw "Package restore failed with exit code $LASTEXITCODE." }

if (-not $SkipTests) {
    dotnet run --project $tests -c Release
    if ($LASTEXITCODE -ne 0) { throw "Core tests failed with exit code $LASTEXITCODE." }
}

dotnet publish $project -c Release -r win-x64 --self-contained true --no-restore -o $publishRoot `
    -p:WindowsAppSDKSelfContained=true `
    -p:PublishSingleFile=false `
    -p:PublishReadyToRun=false

if ($LASTEXITCODE -ne 0) { throw "WinUI 3 publish failed with exit code $LASTEXITCODE." }

# Keep the generated application resource index with the unpackaged build.
# Omitting it makes compiled Window resources fail with XamlParseException.
foreach ($resourceName in @('MediaShuttle.pri', 'App.xbf', 'MainWindow.xbf')) {
    $resourcePath = Join-Path $buildOutput $resourceName
    if (-not [IO.File]::Exists($resourcePath)) {
        throw "Required WinUI resource was not produced: $resourcePath"
    }

    Copy-Item -LiteralPath $resourcePath -Destination (Join-Path $publishRoot $resourceName) -Force
}

if (Test-Path -LiteralPath $releaseZip) { Remove-Item -LiteralPath $releaseZip -Force }
Compress-Archive -Path (Join-Path $publishRoot '*') -DestinationPath $releaseZip -CompressionLevel Optimal

Write-Output "Published $publishRoot"
Write-Output "Packaged $releaseZip"
