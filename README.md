# Media Shuttle

**Verified camera-card ingest for macOS and Windows.**

Media Shuttle sorts photos and videos into a predictable folder layout, checks every copy with SHA-256, and keeps card erase locked until the source and destination still match.

<div align="center">
  <img src="docs/screenshot.png" alt="Media Shuttle showing a verified transfer" width="900">
</div>

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple)](#download)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=flat-square&logo=windows&logoColor=white)](#download)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](#build)
[![.NET 8](https://img.shields.io/badge/.NET-8-512BD4?style=flat-square&logo=dotnet&logoColor=white)](#build)
[![MIT](https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square)](LICENSE)

## What it does

- Finds camera media in `DCIM`, `M4ROOT`, and `PRIVATE` folders.
- Sorts files into `Camera/Photos/JPEGs`, `Camera/Photos/RAWs`, `Camera/Photos/Other`, and `Camera/Videos`.
- Writes to a temporary file, hashes the card copy and destination copy independently, and publishes only when they match.
- Reuses identical files already at the destination and keeps different name collisions.
- Watches for cards in the background, with optional automatic transfer and native notifications.

Erase is available only after a verified transfer. Before deleting, the app rescans the card and verifies every remaining file against its destination copy. Unknown files keep erase locked. Erasing removes user content; it does not format the card. Type `ERASE EVERYTHING` to confirm. Use the camera's Format command when you need a fresh filesystem.

## Download

Get the latest installer and portable build from [GitHub Releases](https://github.com/AdamNolle/media-shuttle/releases).

- **Windows:** run `MediaShuttle-Setup-v*-win-x64.exe`, or unzip `MediaShuttle-v*-win-x64.zip`. The build is self-contained; no .NET runtime install is needed.
- **macOS:** open `MediaShuttle-v*-macOS-universal.dmg` and drag the app to Applications.

Each release includes a platform-specific SHA-256 checksum file. Unsigned Windows builds may show SmartScreen; unsigned macOS community builds may require Control-click → **Open**.

## Build

### Windows

Requires the .NET 8 SDK and Inno Setup 6 to build the installer.

```powershell
.\windows\build.ps1 -Clean
.\windows\install.ps1
```

Use `-SkipInstaller` for a portable-only build. `build.ps1` runs the core safety suite before packaging.

### macOS

Requires Xcode 26 or later and Swift 6.

```bash
swift run --package-path macos MediaShuttle
swift test --package-path macos --scratch-path /tmp/media-shuttle-tests
./macos/scripts/package-macos.sh 0.1.0
```

## CI and releases

GitHub Actions runs Windows and macOS safety checks on pushes and pull requests. Windows CI uses the online Adlon self-hosted runner when available and falls back to GitHub-hosted Windows; pull requests from forks always use the hosted runner. Tagged Windows releases run on Adlon, while macOS releases use a macOS runner. Both release workflows test and attach their packages to the same GitHub release.

## Privacy

Settings, transfer records, and logs stay on the computer. Media Shuttle makes no network requests and collects no analytics.

## License

[MIT](LICENSE)
