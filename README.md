# Media Shuttle

Media Shuttle is a native Windows camera-media ingest app built with WinUI 3. Connect camera storage, verify the detected media, and send it to a clean editing layout in any destination folder you choose:

```text
Your destination\
├── Photos\
│   ├── JPEGs\
│   ├── RAWs\
│   └── Other\
└── Videos\
```

The default destination is `Desktop\Camera`, and the selection is remembered.

## What it does

- Watches removable drives for Sony-style `DCIM`, `M4ROOT`, and `PRIVATE` media layouts.
- Sorts JPG/JPEG into `Photos\JPEGs`, ARW/DNG into `Photos\RAWs`, other still formats into `Photos\Other`, and video into `Videos`.
- Lets you choose and persist any accessible destination folder on the computer.
- Offers System, Light, and Dark appearance modes.
- Optionally groups each category into `YYYY-MM-DD` folders.
- Writes through a uniquely named `.partial-*` file so an interrupted copy is never presented as complete.
- SHA-256 verifies every destination file before recording the transfer as safe.
- Detects identical existing files and verifies them instead of copying duplicates.
- Preserves existing files by generating numbered names when the contents differ.
- Can start with Windows, watch in the notification area, and transfer automatically.

## Safe full-card erase

Erase is deliberately gated. It becomes available only after Media Shuttle has a verified transfer session for the connected volume. Immediately before deletion, the app:

1. confirms the volume root and volume serial number;
2. rescans every remaining supported media file;
3. verifies that each file belongs to the transfer session;
4. recalculates SHA-256 for both the card file and destination copy;
5. blocks the erase if any file is new, missing, changed, or unverifiable.

The confirmation dialog requires both an acknowledgment checkbox and the typed phrase `ERASE EVERYTHING`.

When confirmed, Media Shuttle removes all user content from the card—not only photos and videos—including camera databases and sidecar folders. Read-only and hidden attributes are cleared before deletion, fixing erase failures caused by protected camera files. Windows may preserve or recreate `$RECYCLE.BIN` and `System Volume Information`; only those Windows-managed folders are accepted by the final post-erase scan.

This is a file-level erase, not a filesystem format. For a freshly initialized camera filesystem, use the camera's own Format command after the files are safely transferred.

## Supported media

- JPEG: JPG, JPEG
- RAW: ARW, DNG
- Other photos: HEIF, HEIC, HIF, TIF, TIFF, PNG
- Video: MP4, MOV, MXF, MTS, M2TS, AVI

macOS AppleDouble sidecars whose names begin with `._` are ignored during ingest.

## Install a release

Download `MediaShuttle-v2.0.0-win-x64.zip` from the Releases page, extract it, and run `MediaShuttle.exe`. The release is self-contained for Windows 10/11 x64 and does not require a separate .NET installation.

## Build from source

Requirements:

- Windows 10 version 1809 or later, or Windows 11
- Windows x64
- .NET 8 SDK or later
- PowerShell 5.1 or later

From the repository root:

```powershell
.\build.ps1 -Clean
```

The build restores the official Microsoft Windows App SDK, generates the fast-card icon, runs the core safety tests, publishes a self-contained WinUI 3 build, and creates:

```text
artifacts\MediaShuttle-v2.0.0-win-x64.zip
```

To build and install for the current Windows user:

```powershell
.\install.ps1 -EnableStartup
```

The installer places the app in `%LOCALAPPDATA%\Programs\Media Shuttle`, creates Desktop and Start Menu shortcuts, and optionally enables background startup. The media destination contains media folders only.

## Test

```powershell
dotnet run --project .\tests\MediaShuttle.Core.Tests\MediaShuttle.Core.Tests.csproj -c Release
```

The test harness covers classification, settings persistence, verified copy, duplicate detection, collision handling, unverified-file blocking, read-only-file erase, non-media cleanup, and post-erase verification.

## Data and logs

Settings, transfer records, and logs are stored in:

```text
%LOCALAPPDATA%\Media Shuttle
```

No telemetry or cloud service is used.
