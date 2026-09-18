# Media Shuttle

A focused Windows ingest utility for Sony camera cards. Media Shuttle watches
for a camera-style `DCIM`, `M4ROOT`, or `PRIVATE` layout, then copies and
verifies media into a clean editing structure:

```text
Desktop/Camera/
|-- Photos/
|   |-- JPEGs/
|   |-- RAWs/
|   `-- Other/
`-- Videos/
```

## Highlights

- Clickable `MediaShuttle.exe` launcher with a native app icon and no console.
- Clicking the launcher again restores the running app window.
- Automatic card detection with a Windows startup option.
- Atomic copies: incomplete files retain a `.partial-*` suffix and are never
  presented as completed media.
- SHA-256 verification of every transferred file.
- Duplicate detection that hashes an existing destination before skipping it.
- Collision-safe numbered names; existing files are never overwritten.
- Explicit safe erase unlocked only after a verified transfer. The app
  re-verifies card files before deleting them and preserves Sony card folders.
- macOS AppleDouble files beginning with `._` are ignored.

## Supported formats

Photos: ARW, JPG, JPEG, HEIF, HEIC, HIF, DNG, TIFF, TIF, PNG

Video: MP4, MOV, MXF, MTS, M2TS, AVI

ARW and DNG files go to `Photos/RAWs`. JPG and JPEG files go to
`Photos/JPEGs`. Other supported still formats go to `Photos/Other`.

## Build

Open Windows PowerShell in the repository and run:

```powershell
.\build.ps1 -Clean
```

The build uses the Windows .NET Framework C# compiler already included with
Windows. Output is written to `dist/`.

To build and install it for the current Windows user:

```powershell
.\install.ps1 -EnableStartup
```

This creates a clickable `Media Shuttle` shortcut on the Desktop and in the
Start Menu. The installed runtime lives in the current user's local app-data
folder, keeping `Desktop\Camera` clean and media-only.

To run the engine self-test directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA `
  -File '.\src\App\Sony Media Shuttle.ps1' -SelfTest
```

## Safety model

Media Shuttle does not format cards. Safe erase only removes media recorded in
the latest verified session, after matching each source file's size and
SHA-256 hash again. For a true filesystem reformat, use the camera's own Format
command.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- .NET Framework 4.x
