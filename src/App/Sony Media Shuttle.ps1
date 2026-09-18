[CmdletBinding()]
param(
    [switch]$Background,
    [switch]$SelfTest,
    [string]$RenderPreview,
    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'

function Get-DefaultCameraRoot {
    Join-Path ([Environment]::GetFolderPath('Desktop')) 'Camera'
}

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Get-DefaultCameraRoot
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)

$script:PhotoExtensions = @('.jpg', '.jpeg', '.arw', '.heif', '.heic', '.hif', '.dng', '.tif', '.tiff', '.png')
$script:VideoExtensions = @('.mp4', '.mov', '.mxf', '.mts', '.m2ts', '.avi')

$script:MediaWorker = {
    param(
        [hashtable]$State,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$LogQueue,
        [string]$Mode,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [bool]$GroupByDate,
        [string]$ManifestPath,
        [string[]]$PhotoExtensions,
        [string[]]$VideoExtensions
    )

    $ErrorActionPreference = 'Stop'

    function Write-WorkerLog([string]$Message) {
        $stamp = [DateTime]::Now.ToString('HH:mm:ss')
        $LogQueue.Enqueue("$stamp  $Message")
    }

    function Get-Sha256([string]$Path) {
        $hashStream = $null
        $hashAlgorithm = $null
        try {
            $hashStream = New-Object IO.FileStream(
                $Path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read,
                1048576,
                [IO.FileOptions]::SequentialScan
            )
            $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
            $hashBytes = $hashAlgorithm.ComputeHash($hashStream)
            return ([BitConverter]::ToString($hashBytes)).Replace('-', '')
        }
        finally {
            if ($null -ne $hashAlgorithm) { $hashAlgorithm.Dispose() }
            if ($null -ne $hashStream) { $hashStream.Dispose() }
        }
    }

    function Get-UniqueDestination([string]$Directory, [string]$FileName) {
        $candidate = Join-Path $Directory $FileName
        if (-not [IO.File]::Exists($candidate)) { return $candidate }
        $stem = [IO.Path]::GetFileNameWithoutExtension($FileName)
        $extension = [IO.Path]::GetExtension($FileName)
        $number = 2
        while ($true) {
            $candidate = Join-Path $Directory ("{0} ({1}){2}" -f $stem, $number, $extension)
            if (-not [IO.File]::Exists($candidate)) { return $candidate }
            $number++
        }
    }

    function Convert-Bytes([long]$Bytes) {
        if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
        if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
        return "$Bytes B"
    }

    function Copy-And-Verify([IO.FileInfo]$Source, [string]$TargetPath) {
        $temporaryPath = $TargetPath + '.partial-' + [Guid]::NewGuid().ToString('N')
        $sourceStream = $null
        $destinationStream = $null
        $sha = $null
        try {
            $sourceStream = New-Object IO.FileStream(
                $Source.FullName,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read,
                1048576,
                [IO.FileOptions]::SequentialScan
            )
            $destinationStream = New-Object IO.FileStream(
                $temporaryPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None,
                1048576,
                [IO.FileOptions]::SequentialScan
            )
            $sha = [Security.Cryptography.SHA256]::Create()
            $buffer = New-Object byte[] 1048576
            while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($State.CancelRequested) { throw [OperationCanceledException]::new('Transfer cancelled.') }
                [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
                $destinationStream.Write($buffer, 0, $read)
                $State.ProcessedBytes = [long]$State.ProcessedBytes + $read
            }
            $empty = New-Object byte[] 0
            [void]$sha.TransformFinalBlock($empty, 0, 0)
            $sourceHash = ([BitConverter]::ToString($sha.Hash)).Replace('-', '')
            $destinationStream.Flush()
            $destinationStream.Dispose()
            $destinationStream = $null
            $sourceStream.Dispose()
            $sourceStream = $null

            [IO.File]::SetLastWriteTime($temporaryPath, $Source.LastWriteTime)
            $State.Phase = 'VERIFYING'
            $destinationHash = Get-Sha256 $temporaryPath
            if ($sourceHash -ne $destinationHash) {
                throw "Verification failed for $($Source.Name)."
            }
            [IO.File]::Move($temporaryPath, $TargetPath)
            return $sourceHash
        }
        catch {
            if ([IO.File]::Exists($temporaryPath)) {
                [IO.File]::Delete($temporaryPath)
            }
            throw
        }
        finally {
            if ($null -ne $destinationStream) { $destinationStream.Dispose() }
            if ($null -ne $sourceStream) { $sourceStream.Dispose() }
            if ($null -ne $sha) { $sha.Dispose() }
        }
    }

    function Test-SafeChildPath([string]$Candidate, [string]$Root) {
        $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        $normalizedCandidate = [IO.Path]::GetFullPath($Candidate)
        return $normalizedCandidate.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)
    }

    try {
        $State.Done = $false
        $State.Success = $false
        $State.Error = ''
        $State.StartedAt = [DateTime]::Now.ToString('o')

        if ($Mode -eq 'Transfer') {
            if (-not [IO.Directory]::Exists($SourceRoot)) { throw "The source card is no longer available." }
            if (-not [IO.Directory]::Exists($DestinationRoot)) {
                [void][IO.Directory]::CreateDirectory($DestinationRoot)
            }
            $photosRoot = Join-Path $DestinationRoot 'Photos'
            $videosRoot = Join-Path $DestinationRoot 'Videos'
            $jpegRoot = Join-Path $photosRoot 'JPEGs'
            $rawRoot = Join-Path $photosRoot 'RAWs'
            [void][IO.Directory]::CreateDirectory($photosRoot)
            [void][IO.Directory]::CreateDirectory($videosRoot)
            [void][IO.Directory]::CreateDirectory($jpegRoot)
            [void][IO.Directory]::CreateDirectory($rawRoot)
            foreach ($stalePartial in @(Get-ChildItem -LiteralPath $photosRoot, $videosRoot -File -Recurse -Filter '*.partial-*' -ErrorAction SilentlyContinue)) {
                try { [IO.File]::Delete($stalePartial.FullName) } catch {}
            }

            $State.Status = 'SCANNING CARD'
            $State.Phase = 'INDEXING'
            Write-WorkerLog "Scanning $SourceRoot for camera media"
            $media = New-Object Collections.Generic.List[IO.FileInfo]
            foreach ($file in (Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
                if ($file.Name.StartsWith('._', [StringComparison]::Ordinal)) { continue }
                $extension = $file.Extension.ToLowerInvariant()
                if (($PhotoExtensions -contains $extension) -or ($VideoExtensions -contains $extension)) {
                    [void]$media.Add($file)
                }
            }
            if ($media.Count -eq 0) { throw 'No supported photos or videos were found on this card.' }

            $totalBytes = [long]0
            foreach ($item in $media) { $totalBytes += $item.Length }
            $State.TotalBytes = $totalBytes
            $State.TotalFiles = $media.Count

            $destinationDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($DestinationRoot))
            if ($destinationDrive.AvailableFreeSpace -lt ($totalBytes + 1073741824)) {
                throw ("Not enough free space. The card contains {0}; keep at least 1 GB free beyond that." -f (Convert-Bytes $totalBytes))
            }

            $verifiedFiles = New-Object Collections.Generic.List[object]
            $copiedCount = 0
            $skippedCount = 0
            $processedBeforeFile = [long]0

            foreach ($sourceFile in $media) {
                if ($State.CancelRequested) { throw [OperationCanceledException]::new('Transfer cancelled.') }
                $State.CurrentFile = $sourceFile.Name
                $State.Phase = 'COPYING'
                $extension = $sourceFile.Extension.ToLowerInvariant()
                if ($PhotoExtensions -contains $extension) {
                    if (@('.arw', '.dng') -contains $extension) {
                        $categoryRoot = $rawRoot
                        $category = 'RAW'
                    }
                    elseif (@('.jpg', '.jpeg') -contains $extension) {
                        $categoryRoot = $jpegRoot
                        $category = 'JPEG'
                    }
                    else {
                        $categoryRoot = Join-Path $photosRoot 'Other'
                        $category = 'Other photo'
                    }
                }
                else {
                    $categoryRoot = $videosRoot
                    $category = 'Video'
                }
                if ($GroupByDate) {
                    $categoryRoot = Join-Path $categoryRoot $sourceFile.LastWriteTime.ToString('yyyy-MM-dd')
                }
                if (-not [IO.Directory]::Exists($categoryRoot)) {
                    [void][IO.Directory]::CreateDirectory($categoryRoot)
                }

                $targetPath = Join-Path $categoryRoot $sourceFile.Name
                $hash = $null
                $wasSkipped = $false
                if ([IO.File]::Exists($targetPath)) {
                    $existing = Get-Item -LiteralPath $targetPath
                    if ($existing.Length -eq $sourceFile.Length) {
                        $State.Phase = 'CHECKING DUPLICATE'
                        $sourceHash = Get-Sha256 $sourceFile.FullName
                        $destinationHash = Get-Sha256 $targetPath
                        if ($sourceHash -eq $destinationHash) {
                            $hash = $sourceHash
                            $wasSkipped = $true
                            $skippedCount++
                            $State.ProcessedBytes = $processedBeforeFile + $sourceFile.Length
                            Write-WorkerLog "Verified existing $($sourceFile.Name)"
                        }
                    }
                    if (-not $wasSkipped) {
                        $targetPath = Get-UniqueDestination $categoryRoot $sourceFile.Name
                    }
                }

                if (-not $wasSkipped) {
                    Write-WorkerLog "Copying $($sourceFile.Name)"
                    $hash = Copy-And-Verify $sourceFile $targetPath
                    $copiedCount++
                    Write-WorkerLog "Verified $($sourceFile.Name)"
                }

                $processedBeforeFile += $sourceFile.Length
                $State.ProcessedBytes = $processedBeforeFile
                $State.CopiedCount = $copiedCount
                $State.SkippedCount = $skippedCount
                $State.VerifiedCount = $verifiedFiles.Count + 1
                [void]$verifiedFiles.Add([pscustomobject]@{
                    Source = $sourceFile.FullName
                    Destination = $targetPath
                    Hash = $hash
                    Size = $sourceFile.Length
                    Category = $category
                })
            }

            $manifest = [ordered]@{
                SessionId = [Guid]::NewGuid().ToString('N')
                Started = $State.StartedAt
                Completed = [DateTime]::Now.ToString('o')
                Status = 'Verified'
                SourceRoot = $SourceRoot
                SourceLabel = $State.SourceLabel
                DestinationRoot = $DestinationRoot
                TotalBytes = $totalBytes
                TotalFiles = $media.Count
                CopiedCount = $copiedCount
                SkippedCount = $skippedCount
                WipedCount = 0
                VerifiedFiles = $verifiedFiles
            }
            $manifestDirectory = Split-Path -Parent $ManifestPath
            if (-not [IO.Directory]::Exists($manifestDirectory)) {
                [void][IO.Directory]::CreateDirectory($manifestDirectory)
            }
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
            $State.ManifestPath = $ManifestPath
            $State.Status = 'TRANSFER VERIFIED'
            $State.Phase = 'COMPLETE'
            $State.Success = $true
            $State.CompletedAt = [DateTime]::Now.ToString('o')
            Write-WorkerLog ("Complete: {0} copied, {1} already safe" -f $copiedCount, $skippedCount)
        }
        elseif ($Mode -eq 'Wipe') {
            if (-not [IO.File]::Exists($ManifestPath)) { throw 'The verified transfer record could not be found.' }
            $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
            if ($manifest.Status -ne 'Verified') { throw 'Only a fully verified transfer can be erased.' }
            if (-not [IO.Directory]::Exists($SourceRoot)) { throw 'The original card is no longer connected.' }
            if ([IO.Path]::GetFullPath($manifest.SourceRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')) {
                throw 'The connected card does not match the verified transfer.'
            }

            $State.TotalFiles = @($manifest.VerifiedFiles).Count
            $wipeBytes = [long]0
            foreach ($record in @($manifest.VerifiedFiles)) { $wipeBytes += [long]$record.Size }
            $State.TotalBytes = $wipeBytes
            $State.ProcessedBytes = 0
            $State.Status = 'ERASING VERIFIED MEDIA'
            $State.Phase = 'RE-VERIFYING'
            $erased = 0
            $processed = [long]0

            foreach ($record in @($manifest.VerifiedFiles)) {
                if ($State.CancelRequested) { throw [OperationCanceledException]::new('Erase cancelled.') }
                $sourcePath = [string]$record.Source
                $State.CurrentFile = [IO.Path]::GetFileName($sourcePath)
                if (-not (Test-SafeChildPath $sourcePath $SourceRoot)) {
                    throw "Safety check rejected a path outside the card."
                }
                if ([IO.File]::Exists($sourcePath)) {
                    $current = Get-Item -LiteralPath $sourcePath
                    if ($current.Length -ne [long]$record.Size) {
                        throw "The card file changed after transfer: $($current.Name)."
                    }
                    $currentHash = Get-Sha256 $sourcePath
                    if ($currentHash -ne [string]$record.Hash) {
                        throw "The card file no longer matches its verified copy: $($current.Name)."
                    }
                    $State.Phase = 'ERASING'
                    [IO.File]::Delete($sourcePath)
                    $erased++
                    $State.WipedCount = $erased
                    Write-WorkerLog "Erased verified media $($current.Name)"
                }
                $processed += [long]$record.Size
                $State.ProcessedBytes = $processed
            }

            foreach ($mediaFolderName in @('DCIM', 'M4ROOT', 'PRIVATE')) {
                $mediaFolder = Join-Path $SourceRoot $mediaFolderName
                if ([IO.Directory]::Exists($mediaFolder)) {
                    $directories = Get-ChildItem -LiteralPath $mediaFolder -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
                    foreach ($directory in $directories) {
                        if (@([IO.Directory]::EnumerateFileSystemEntries($directory.FullName)).Count -eq 0) {
                            [IO.Directory]::Delete($directory.FullName)
                        }
                    }
                }
            }

            $manifest.Status = 'Media erased'
            $manifest.WipedCount = $erased
            $manifest | Add-Member -NotePropertyName ErasedAt -NotePropertyValue ([DateTime]::Now.ToString('o')) -Force
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
            $State.Status = 'CARD MEDIA ERASED'
            $State.Phase = 'COMPLETE'
            $State.Success = $true
            $State.CompletedAt = [DateTime]::Now.ToString('o')
            Write-WorkerLog "$erased verified media files erased; card structure preserved"
        }
        else {
            throw "Unknown worker mode: $Mode"
        }
    }
    catch [OperationCanceledException] {
        $State.Error = $_.Exception.Message
        $State.Status = 'CANCELLED'
        $State.Phase = 'CANCELLED'
        Write-WorkerLog $_.Exception.Message
    }
    catch {
        $State.Error = $_.Exception.Message
        $State.Status = 'NEEDS ATTENTION'
        $State.Phase = 'ERROR'
        Write-WorkerLog ("Error: " + $_.Exception.Message)
    }
    finally {
        $State.Done = $true
    }
}

function Invoke-SelfTest {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SonyMediaShuttle-SelfTest-' + [Guid]::NewGuid().ToString('N'))
    $source = Join-Path $testRoot 'CARD'
    $destination = Join-Path $testRoot 'Camera'
    $manifest = Join-Path $testRoot 'session.json'
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'DCIM\100MSDCF'))
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'PRIVATE\M4ROOT\CLIP'))
        [void][IO.Directory]::CreateDirectory($destination)
        [IO.File]::WriteAllBytes((Join-Path $source 'DCIM\100MSDCF\DSC00001.JPG'), [Text.Encoding]::UTF8.GetBytes('photo-one'))
        [IO.File]::WriteAllBytes((Join-Path $source 'DCIM\100MSDCF\DSC00001.ARW'), [Text.Encoding]::UTF8.GetBytes('raw-one'))
        [IO.File]::WriteAllBytes((Join-Path $source 'DCIM\100MSDCF\._DSC00001.JPG'), [Text.Encoding]::UTF8.GetBytes('apple-double'))
        [IO.File]::WriteAllBytes((Join-Path $source 'PRIVATE\M4ROOT\CLIP\C0001.MP4'), [Text.Encoding]::UTF8.GetBytes('video-one'))
        [IO.File]::WriteAllText((Join-Path $source 'PRIVATE\M4ROOT\CLIP\C0001.XML'), '<metadata />')

        $state = [hashtable]::Synchronized(@{
            Done = $false; Success = $false; Error = ''; CancelRequested = $false
            ProcessedBytes = [long]0; TotalBytes = [long]0; TotalFiles = 0
            CopiedCount = 0; SkippedCount = 0; VerifiedCount = 0; WipedCount = 0
            SourceLabel = 'SELFTEST'
        })
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $testPowerShell = [PowerShell]::Create()
        [void]$testPowerShell.AddScript($script:MediaWorker.ToString())
        [void]$testPowerShell.AddArgument($state)
        [void]$testPowerShell.AddArgument($queue)
        [void]$testPowerShell.AddArgument('Transfer')
        [void]$testPowerShell.AddArgument($source)
        [void]$testPowerShell.AddArgument($destination)
        [void]$testPowerShell.AddArgument($false)
        [void]$testPowerShell.AddArgument($manifest)
        [void]$testPowerShell.AddArgument($script:PhotoExtensions)
        [void]$testPowerShell.AddArgument($script:VideoExtensions)
        try { [void]$testPowerShell.Invoke() } finally { $testPowerShell.Dispose() }
        if (-not $state.Success) { throw "Transfer self-test failed: $($state.Error)" }
        $expected = @(
            (Join-Path $destination 'Photos\JPEGs\DSC00001.JPG'),
            (Join-Path $destination 'Photos\RAWs\DSC00001.ARW'),
            (Join-Path $destination 'Videos\C0001.MP4')
        )
        foreach ($path in $expected) {
            if (-not [IO.File]::Exists($path)) { throw "Missing self-test output: $path" }
        }
        if ([IO.File]::Exists((Join-Path $destination 'Photos\JPEGs\._DSC00001.JPG'))) { throw 'AppleDouble sidecar was treated as a photo.' }
        if ([IO.File]::Exists((Join-Path $destination 'Videos\C0001.XML'))) { throw 'Unsupported metadata was copied.' }

        $state.Done = $false
        $state.Success = $false
        $state.CancelRequested = $false
        & $script:MediaWorker $state $queue 'Wipe' $source $destination $false $manifest $script:PhotoExtensions $script:VideoExtensions
        if (-not $state.Success) { throw "Erase self-test failed: $($state.Error)" }
        foreach ($sourceMedia in @(
            (Join-Path $source 'DCIM\100MSDCF\DSC00001.JPG'),
            (Join-Path $source 'DCIM\100MSDCF\DSC00001.ARW'),
            (Join-Path $source 'PRIVATE\M4ROOT\CLIP\C0001.MP4')
        )) {
            if ([IO.File]::Exists($sourceMedia)) { throw "Self-test erase left media behind: $sourceMedia" }
        }
        if (-not [IO.File]::Exists((Join-Path $source 'PRIVATE\M4ROOT\CLIP\C0001.XML'))) { throw 'Erase touched an unverified metadata file.' }
        Write-Output 'SELFTEST PASSED: classification, atomic copy, SHA-256 verification, manifest, and verified-media erase.'
    }
    finally {
        if ([IO.Directory]::Exists($testRoot)) {
            [IO.Directory]::Delete($testRoot, $true)
        }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$createdNew = $false
$mutex = $null
if ([string]::IsNullOrWhiteSpace($RenderPreview)) {
    $mutex = New-Object Threading.Mutex($true, 'Local\SonyMediaShuttle', [ref]$createdNew)
    if (-not $createdNew) {
        [void][Windows.MessageBox]::Show('Sony Media Shuttle is already running. Look for the red shutter icon in the notification area.', 'Already running', 'OK', 'Information')
        exit 0
    }
}

if (-not [IO.Directory]::Exists($DataRoot)) { [void][IO.Directory]::CreateDirectory($DataRoot) }
[void][IO.Directory]::CreateDirectory((Join-Path $DataRoot 'Photos'))
[void][IO.Directory]::CreateDirectory((Join-Path $DataRoot 'Photos\JPEGs'))
[void][IO.Directory]::CreateDirectory((Join-Path $DataRoot 'Photos\RAWs'))
[void][IO.Directory]::CreateDirectory((Join-Path $DataRoot 'Videos'))
$appDataRoot = Join-Path $DataRoot '.sony-media-shuttle'
$sessionsRoot = Join-Path $appDataRoot 'sessions'
[void][IO.Directory]::CreateDirectory($sessionsRoot)
try { (Get-Item -LiteralPath $appDataRoot -Force).Attributes = (Get-Item -LiteralPath $appDataRoot -Force).Attributes -bor [IO.FileAttributes]::Hidden } catch {}
$settingsPath = Join-Path $appDataRoot 'settings.json'
$appLogPath = Join-Path $appDataRoot 'app.log'

function Get-Settings {
    $defaults = [ordered]@{
        AutoTransfer = $true
        GroupByDate = $false
        Notifications = $true
    }
    if ([IO.File]::Exists($settingsPath)) {
        try {
            $loaded = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            foreach ($name in @('AutoTransfer', 'GroupByDate', 'Notifications')) {
                if ($null -ne $loaded.$name) { $defaults[$name] = [bool]$loaded.$name }
            }
        }
        catch {}
    }
    return [pscustomobject]$defaults
}

function Save-Settings {
    $script:Settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Get-StartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Sony Media Shuttle.lnk'
}

function Set-StartWithWindows([bool]$Enabled) {
    $shortcutPath = Get-StartupShortcutPath
    if ($Enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $launcherPath = Join-Path $PSScriptRoot 'MediaShuttle.exe'
        if ([IO.File]::Exists($launcherPath)) {
            $shortcut.TargetPath = $launcherPath
            $shortcut.Arguments = '--background'
            $iconPath = Join-Path $PSScriptRoot 'MediaShuttle.ico'
            if ([IO.File]::Exists($iconPath)) { $shortcut.IconLocation = $iconPath }
        }
        else {
            $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $escapedScript = $PSCommandPath.Replace('"', '""')
            $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$escapedScript`" -Background"
        }
        $shortcut.WorkingDirectory = Split-Path -Parent $PSCommandPath
        $shortcut.Description = 'Watch for Sony camera cards and transfer verified media.'
        $shortcut.Save()
    }
    elseif ([IO.File]::Exists($shortcutPath)) {
        [IO.File]::Delete($shortcutPath)
    }
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-CardCandidates {
    $destinationDriveRoot = [IO.Path]::GetPathRoot($DataRoot)
    $candidates = New-Object Collections.Generic.List[object]
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            if ($drive.RootDirectory.FullName -eq $destinationDriveRoot) { continue }
            $root = $drive.RootDirectory.FullName
            $hasCameraLayout = [IO.Directory]::Exists((Join-Path $root 'DCIM')) -or
                               [IO.Directory]::Exists((Join-Path $root 'M4ROOT')) -or
                               [IO.Directory]::Exists((Join-Path $root 'PRIVATE'))
            if (-not $hasCameraLayout) { continue }
            [void]$candidates.Add([pscustomobject]@{
                Root = $root
                Label = $(if ([string]::IsNullOrWhiteSpace($drive.VolumeLabel)) { 'CAMERA MEDIA' } else { $drive.VolumeLabel })
                TotalSize = $drive.TotalSize
                FreeSpace = $drive.AvailableFreeSpace
                DriveType = $drive.DriveType.ToString()
            })
        }
        catch {}
    }
    return $candidates
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sony Media Shuttle" Width="1060" Height="720" MinWidth="920" MinHeight="640"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanResizeWithGrip" FontFamily="Segoe UI Variable Text, Segoe UI"
        TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#F4F2ED"/>
    <SolidColorBrush x:Key="Muted" Color="#97989D"/>
    <SolidColorBrush x:Key="Hairline" Color="#2A2C31"/>
    <SolidColorBrush x:Key="Panel" Color="#111216"/>
    <SolidColorBrush x:Key="Red" Color="#FF3B30"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    </Style>
    <Style x:Key="UtilityButton" TargetType="Button">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Background" Value="#17191E"/>
      <Setter Property="BorderBrush" Value="#34363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Surface" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Background" Value="#23252B"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.76"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource UtilityButton}">
      <Setter Property="Background" Value="{StaticResource Red}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Red}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Height" Value="48"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Surface" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <Grid Margin="18,0">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <TextBlock Text="&#x2192;" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="18" Foreground="White"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Background" Value="#FF5249"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChromeButton" TargetType="Button">
      <Setter Property="Width" Value="34"/><Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#A8A9AD"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="FontSize" Value="14"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" CornerRadius="6" Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#292B31"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E2DD"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>

  <Border x:Name="OuterShell" CornerRadius="18" Background="#0B0C0F" BorderBrush="#303138" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="34" ShadowDepth="8" Opacity="0.58" Color="#000000"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="56"/><RowDefinition Height="*"/></Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Background="#0E0F12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
          <Grid Width="24" Height="24" Margin="0,0,12,0">
            <Ellipse Stroke="#FF3B30" StrokeThickness="2"/>
            <Ellipse Width="7" Height="7" Fill="#FF3B30"/>
            <Line X1="12" Y1="1" X2="12" Y2="5" Stroke="#FF3B30" StrokeThickness="2"/>
          </Grid>
          <TextBlock Text="SHUTTER" FontWeight="Bold" FontSize="13" VerticalAlignment="Center"/>
          <TextBlock Text=" / /  MEDIA SHUTTLE" Foreground="#777980" FontFamily="Consolas" FontSize="11" VerticalAlignment="Center"/>
          <Border Margin="18,0,0,0" Background="#1A1B20" BorderBrush="#303139" BorderThickness="1" CornerRadius="12" Padding="10,4">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="#6F7179" Margin="0,0,7,0"/>
              <TextBlock x:Name="TopStatus" Text="AWAITING MEDIA" FontFamily="Consolas" FontSize="9" Foreground="#AEB0B7"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,12,0" VerticalAlignment="Center">
          <Button x:Name="SettingsButton" Content="&#x2699;" ToolTip="Settings" Style="{StaticResource ChromeButton}"/>
          <Button x:Name="MinimizeButton" Content="&#x2014;" ToolTip="Minimize" Style="{StaticResource ChromeButton}"/>
          <Button x:Name="CloseButton" Content="&#x00D7;" ToolTip="Keep running in tray" Style="{StaticResource ChromeButton}"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition Width="284"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

        <Border Grid.Column="0" Background="#101115" BorderBrush="#292A30" BorderThickness="0,1,1,0" CornerRadius="0,0,0,18">
          <Grid Margin="24">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel>
              <TextBlock Text="SOURCE / 01" FontFamily="Consolas" FontSize="10" Foreground="#797B82"/>
              <Grid Width="176" Height="154" HorizontalAlignment="Left" Margin="0,22,0,20">
                <Path Data="M18,9 L125,9 L158,42 L158,143 L18,143 Z" Fill="#181A1F" Stroke="#4A4C54" StrokeThickness="1"/>
                <Path Data="M28,20 L120,20 L147,47 L147,132 L28,132 Z" Fill="#0C0D10" Stroke="#292B31" StrokeThickness="1"/>
                <Path Data="M125,9 L125,42 L158,42" Fill="Transparent" Stroke="#696B73" StrokeThickness="1"/>
                <Border Width="4" Height="58" Background="#FF3B30" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="28,30,0,0"/>
                <TextBlock Text="CF" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="34" FontWeight="Bold" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="43,28,0,0"/>
                <TextBlock Text="EXPRESS" FontFamily="Consolas" FontSize="11" Foreground="#BCBEC5" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="45,69,0,0"/>
                <TextBlock Text="TYPE A / SOURCE MEDIA" FontFamily="Consolas" FontSize="8" Foreground="#6F7179" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="44,91,0,0"/>
                <Grid HorizontalAlignment="Left" VerticalAlignment="Top" Margin="44,111,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="8"/><ColumnDefinition Width="8"/><ColumnDefinition Width="8"/><ColumnDefinition Width="8"/><ColumnDefinition Width="8"/><ColumnDefinition Width="8"/></Grid.ColumnDefinitions>
                  <Rectangle Width="5" Height="10" Fill="#4B4D54"/><Rectangle Grid.Column="1" Width="5" Height="10" Fill="#4B4D54"/><Rectangle Grid.Column="2" Width="5" Height="10" Fill="#4B4D54"/><Rectangle Grid.Column="3" Width="5" Height="10" Fill="#4B4D54"/><Rectangle Grid.Column="4" Width="5" Height="10" Fill="#4B4D54"/><Rectangle Grid.Column="5" Width="5" Height="10" Fill="#4B4D54"/>
                </Grid>
              </Grid>
              <TextBlock x:Name="CardLabel" Text="NO CARD CONNECTED" FontWeight="SemiBold" FontSize="17"/>
              <TextBlock x:Name="CardDetail" Text="Insert your Sony media to begin." Foreground="#8E9097" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>

            <StackPanel Grid.Row="1" Margin="0,26,0,0">
              <Border BorderBrush="#2B2D33" BorderThickness="0,1,0,0" Padding="0,15,0,0">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <StackPanel><TextBlock Text="ASSETS" FontFamily="Consolas" FontSize="9" Foreground="#70727A"/><TextBlock x:Name="AssetCount" Text="&#x2014;" FontFamily="Consolas" FontSize="20" Margin="0,5,0,0"/></StackPanel>
                  <StackPanel Grid.Column="1"><TextBlock Text="FOOTAGE" FontFamily="Consolas" FontSize="9" Foreground="#70727A"/><TextBlock x:Name="MediaSize" Text="&#x2014;" FontFamily="Consolas" FontSize="20" Margin="0,5,0,0"/></StackPanel>
                </Grid>
              </Border>
            </StackPanel>

            <StackPanel Grid.Row="3">
              <TextBlock Text="DESTINATION" FontFamily="Consolas" FontSize="9" Foreground="#70727A"/>
              <TextBlock x:Name="DestinationPath" Text="Desktop\Camera" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,6,0,10"/>
              <Button x:Name="OpenFolderButton" Content="OPEN CAMERA FOLDER  &#x2197;" Style="{StaticResource UtilityButton}"/>
            </StackPanel>
          </Grid>
        </Border>

        <Grid Grid.Column="1" Background="#0B0C0F">
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="100"/></Grid.RowDefinitions>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <Grid Margin="42,34,42,28">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="210"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="AUTOMATED INGEST / VERIFIED" FontFamily="Consolas" FontSize="10" Foreground="#FF5A51"/>
                  <TextBlock x:Name="HeroTitle" Text="Your next card&#x0a;has a clear runway." FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="38" FontWeight="SemiBold" LineHeight="42" Margin="0,12,0,0"/>
                  <TextBlock x:Name="HeroSubtitle" Text="Photos and video land exactly where they belong. Every byte is checked before the card can be cleared." Foreground="#9B9DA4" FontSize="13" LineHeight="20" TextWrapping="Wrap" MaxWidth="500" HorizontalAlignment="Left" Margin="0,14,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Bottom" Margin="18,0,0,0">
                  <Button x:Name="TransferButton" Content="SCAN FOR MEDIA" Style="{StaticResource PrimaryButton}"/>
                  <Button x:Name="CancelButton" Content="CANCEL TRANSFER" Style="{StaticResource UtilityButton}" Visibility="Collapsed" Margin="0,8,0,0"/>
                </StackPanel>
              </Grid>

              <Border Grid.Row="1" Background="#111216" BorderBrush="#292B31" BorderThickness="1" CornerRadius="12" Margin="0,32,0,0" Padding="22">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock x:Name="PhaseText" Text="STANDBY" FontFamily="Consolas" FontSize="10" Foreground="#FF5A51"/>
                      <TextBlock Text="  /  " FontFamily="Consolas" FontSize="10" Foreground="#50525A"/>
                      <TextBlock x:Name="CurrentFileText" Text="Waiting for a camera card" FontFamily="Consolas" FontSize="10" Foreground="#A9ABB2" TextTrimming="CharacterEllipsis" MaxWidth="390"/>
                    </StackPanel>
                    <TextBlock x:Name="PercentText" Grid.Column="1" Text="0%" FontFamily="Consolas" FontSize="11"/>
                  </Grid>
                  <Grid Grid.Row="1" Height="8" Margin="0,16,0,14" ClipToBounds="True">
                    <Border Background="#24262C" CornerRadius="4"/>
                    <ProgressBar x:Name="TransferProgress" Minimum="0" Maximum="100" Value="0" Foreground="#FF3B30" Background="Transparent" BorderThickness="0"/>
                  </Grid>
                  <Grid Grid.Row="2">
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="COPIED" FontFamily="Consolas" FontSize="9" Foreground="#70727A"/><TextBlock x:Name="CopiedText" Text="0 files" FontFamily="Consolas" FontSize="13" Margin="0,5,0,0"/></StackPanel>
                    <StackPanel Grid.Column="1"><TextBlock Text="ALREADY SAFE" FontFamily="Consolas" FontSize="9" Foreground="#70727A"/><TextBlock x:Name="SkippedText" Text="0 files" FontFamily="Consolas" FontSize="13" Margin="0,5,0,0"/></StackPanel>
                    <StackPanel Grid.Column="2"><TextBlock Text="PROCESSED" FontFamily="Consolas" FontSize="9" Foreground="#70727A"/><TextBlock x:Name="ProcessedText" Text="0 B" FontFamily="Consolas" FontSize="13" Margin="0,5,0,0"/></StackPanel>
                  </Grid>
                </Grid>
              </Border>

              <Grid Grid.Row="2" Margin="0,28,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="ACTIVITY" FontFamily="Consolas" FontSize="10" Foreground="#7E8088" Margin="0,0,0,12"/>
                  <Border Background="#0E0F12" BorderBrush="#24262C" BorderThickness="1" CornerRadius="10" Padding="16,13">
                    <TextBlock x:Name="ActivityLog" Text="07:45:11  System armed and watching for media." FontFamily="Consolas" FontSize="10" LineHeight="18" Foreground="#A4A6AD" TextWrapping="Wrap"/>
                  </Border>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="22,0,0,0">
                  <TextBlock Text="LAST RUN" FontFamily="Consolas" FontSize="10" Foreground="#7E8088" Margin="0,0,0,12"/>
                  <Border Background="#0E0F12" BorderBrush="#24262C" BorderThickness="1" CornerRadius="10" Padding="16,13" MinHeight="82">
                    <TextBlock x:Name="LastRunText" Text="No transfers yet." FontSize="11" LineHeight="17" Foreground="#A4A6AD" TextWrapping="Wrap"/>
                  </Border>
                </StackPanel>
              </Grid>
            </Grid>
          </ScrollViewer>

          <Border Grid.Row="1" Background="#0E0F12" BorderBrush="#292A30" BorderThickness="0,1,0,0" CornerRadius="0,0,18,0">
            <Grid Margin="28,18">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions>
              <StackPanel VerticalAlignment="Center">
                <TextBlock Text="SAFE CARD CLEAR" FontFamily="Consolas" FontSize="10" Foreground="#FF5A51"/>
                <TextBlock x:Name="WipeDescription" Text="Available only after every transferred file passes SHA-256 verification." Foreground="#90929A" FontSize="11" Margin="0,6,0,0"/>
              </StackPanel>
              <Button x:Name="WipeButton" Grid.Column="1" Content="ERASE VERIFIED MEDIA" Style="{StaticResource UtilityButton}" IsEnabled="False" VerticalAlignment="Center"/>
            </Grid>
          </Border>
        </Grid>

        <Grid x:Name="SettingsOverlay" Grid.ColumnSpan="2" Background="#AA050609" Visibility="Collapsed">
          <Border Width="372" HorizontalAlignment="Right" Background="#131419" BorderBrush="#34363D" BorderThickness="1,0,0,0" Padding="30">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <Grid>
                <TextBlock Text="SYSTEM SETTINGS" FontFamily="Consolas" FontSize="11" Foreground="#FF5A51" VerticalAlignment="Center"/>
                <Button x:Name="CloseSettingsButton" Content="&#x00D7;" HorizontalAlignment="Right" Style="{StaticResource ChromeButton}"/>
              </Grid>
              <StackPanel Grid.Row="1" Margin="0,34,0,0">
                <TextBlock Text="Make every ingest automatic." FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="27" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock Text="The watcher recognizes camera-style DCIM, M4ROOT, and PRIVATE folders. JPEGs and RAWs are separated automatically, and system drives are ignored." Foreground="#9698A0" FontSize="12" LineHeight="18" TextWrapping="Wrap" Margin="0,10,0,26"/>
                <CheckBox x:Name="AutoTransferCheck" Content="Transfer when a camera card appears" IsChecked="True" Margin="0,0,0,20"/>
                <CheckBox x:Name="GroupByDateCheck" Content="Group media into YYYY-MM-DD folders" Margin="0,0,0,20"/>
                <CheckBox x:Name="NotificationsCheck" Content="Show Windows completion notifications" IsChecked="True" Margin="0,0,0,20"/>
                <CheckBox x:Name="StartupCheck" Content="Start Media Shuttle with Windows" Margin="0,0,0,20"/>
                <Border BorderBrush="#2A2C32" BorderThickness="0,1,0,0" Margin="0,12,0,0" Padding="0,22,0,0">
                  <StackPanel>
                    <TextBlock Text="SUPPORTED MEDIA" FontFamily="Consolas" FontSize="9" Foreground="#777981"/>
                    <TextBlock Text="ARW &#x00B7; JPG &#x00B7; HEIF &#x00B7; DNG &#x00B7; TIFF &#x00B7; PNG&#x0a;MP4 &#x00B7; MOV &#x00B7; MXF &#x00B7; MTS &#x00B7; M2TS &#x00B7; AVI" FontFamily="Consolas" FontSize="10" Foreground="#B0B2B9" LineHeight="18" Margin="0,8,0,0"/>
                  </StackPanel>
                </Border>
              </StackPanel>
              <StackPanel Grid.Row="3">
                <TextBlock Text="ERASE POLICY" FontFamily="Consolas" FontSize="9" Foreground="#777981"/>
                <TextBlock Text="Only SHA-256 verified media from the latest run can be erased. Card databases and folder structure stay intact. For a true reformat, use the camera." Foreground="#92949B" FontSize="11" LineHeight="17" TextWrapping="Wrap" Margin="0,8,0,18"/>
                <Button x:Name="DoneSettingsButton" Content="DONE" Style="{StaticResource PrimaryButton}"/>
              </StackPanel>
            </Grid>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$windowIconPath = Join-Path $PSScriptRoot 'MediaShuttle.ico'
if ([IO.File]::Exists($windowIconPath)) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($windowIconPath))) } catch {}
}
$names = @(
    'TitleBar','StatusDot','TopStatus','SettingsButton','MinimizeButton','CloseButton','CardLabel','CardDetail',
    'AssetCount','MediaSize','DestinationPath','OpenFolderButton','HeroTitle','HeroSubtitle','TransferButton',
    'CancelButton','PhaseText','CurrentFileText','PercentText','TransferProgress','CopiedText','SkippedText',
    'ProcessedText','ActivityLog','LastRunText','WipeDescription','WipeButton','SettingsOverlay','CloseSettingsButton',
    'DoneSettingsButton','AutoTransferCheck','GroupByDateCheck','NotificationsCheck','StartupCheck'
)
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }

$DestinationPath.Text = $DataRoot
$script:Settings = Get-Settings
$AutoTransferCheck.IsChecked = $script:Settings.AutoTransfer
$GroupByDateCheck.IsChecked = $script:Settings.GroupByDate
$NotificationsCheck.IsChecked = $script:Settings.Notifications
$StartupCheck.IsChecked = [IO.File]::Exists((Get-StartupShortcutPath))
$script:SettingsReady = $true
$script:AllowExit = $false
$script:Worker = $null
$script:WorkerState = $null
$script:WorkerMode = ''
$script:CurrentCard = $null
$script:LatestManifest = ''
$script:SeenCards = @{}
$script:LogLines = New-Object Collections.Generic.List[string]

function Add-Activity([string]$Text) {
    $line = ([DateTime]::Now.ToString('HH:mm:ss') + '  ' + $Text)
    [void]$script:LogLines.Add($line)
    while ($script:LogLines.Count -gt 5) { $script:LogLines.RemoveAt(0) }
    $ActivityLog.Text = ($script:LogLines -join "`n")
    try { Add-Content -LiteralPath $appLogPath -Value (([DateTime]::Now.ToString('o')) + '  ' + $Text) -Encoding UTF8 } catch {}
}

function Show-Notification([string]$Title, [string]$Text) {
    if (-not $script:Settings.Notifications) { return }
    try {
        $script:TrayIcon.BalloonTipTitle = $Title
        $script:TrayIcon.BalloonTipText = $Text
        $script:TrayIcon.ShowBalloonTip(5000)
    }
    catch {}
}

function Update-CardSummary($Card) {
    $script:CurrentCard = $Card
    if ($null -eq $Card) {
        $CardLabel.Text = 'NO CARD CONNECTED'
        $CardDetail.Text = 'Insert your Sony media to begin.'
        $AssetCount.Text = '-'
        $MediaSize.Text = '-'
        if ($null -eq $script:Worker) {
            $TopStatus.Text = 'AWAITING MEDIA'
            $StatusDot.Fill = '#6F7179'
            $HeroTitle.Text = "Your next card`nhas a clear runway."
            $TransferButton.Content = 'SCAN FOR MEDIA'
        }
        return
    }
    $CardLabel.Text = $Card.Label.ToUpperInvariant()
    $CardDetail.Text = "$($Card.Root)  /  $($Card.DriveType) media"
    $AssetCount.Text = '...'
    $MediaSize.Text = Format-Bytes ($Card.TotalSize - $Card.FreeSpace)
    if ($null -eq $script:Worker) {
        $TopStatus.Text = 'MEDIA DETECTED'
        $StatusDot.Fill = '#FF3B30'
        $HeroTitle.Text = "Media detected.`nReady to ingest."
        $TransferButton.Content = 'TRANSFER + VERIFY'
        $WipeButton.IsEnabled = $false
        if (-not [string]::IsNullOrWhiteSpace($script:LatestManifest) -and [IO.File]::Exists($script:LatestManifest)) {
            try {
                $latestRecord = Get-Content -LiteralPath $script:LatestManifest -Raw | ConvertFrom-Json
                if (($latestRecord.Status -eq 'Verified') -and
                    ([IO.Path]::GetFullPath([string]$latestRecord.SourceRoot).TrimEnd('\') -eq [IO.Path]::GetFullPath([string]$Card.Root).TrimEnd('\'))) {
                    $WipeButton.IsEnabled = $true
                    $WipeDescription.Text = 'A verified transfer record matches this connected card.'
                }
            }
            catch {}
        }
    }
}

function New-WorkerState([string]$Label) {
    [hashtable]::Synchronized(@{
        Done = $false; Success = $false; Error = ''; CancelRequested = $false
        Status = 'PREPARING'; Phase = 'PREPARING'; CurrentFile = ''
        ProcessedBytes = [long]0; TotalBytes = [long]0; TotalFiles = 0
        CopiedCount = 0; SkippedCount = 0; VerifiedCount = 0; WipedCount = 0
        ManifestPath = ''; SourceLabel = $Label; StartedAt = ''; CompletedAt = ''
    })
}

function Start-BackgroundWorker([string]$Mode, [string]$ManifestPath) {
    if ($null -ne $script:Worker) { return }
    if ($null -eq $script:CurrentCard) {
        Add-Activity 'No camera card is available.'
        return
    }
    $script:WorkerMode = $Mode
    $script:WorkerState = New-WorkerState $script:CurrentCard.Label
    $script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    if ($Mode -eq 'Transfer') {
        $sessionName = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.json'
        $ManifestPath = Join-Path $sessionsRoot $sessionName
    }
    $powerShell = [PowerShell]::Create()
    [void]$powerShell.AddScript($script:MediaWorker.ToString())
    [void]$powerShell.AddArgument($script:WorkerState)
    [void]$powerShell.AddArgument($script:LogQueue)
    [void]$powerShell.AddArgument($Mode)
    [void]$powerShell.AddArgument($script:CurrentCard.Root)
    [void]$powerShell.AddArgument($DataRoot)
    [void]$powerShell.AddArgument([bool]$script:Settings.GroupByDate)
    [void]$powerShell.AddArgument($ManifestPath)
    [void]$powerShell.AddArgument($script:PhotoExtensions)
    [void]$powerShell.AddArgument($script:VideoExtensions)
    $handle = $powerShell.BeginInvoke()
    $script:Worker = [pscustomobject]@{ PowerShell = $powerShell; Handle = $handle; ManifestPath = $ManifestPath }

    $TransferButton.IsEnabled = $false
    $CancelButton.Visibility = 'Visible'
    $WipeButton.IsEnabled = $false
    $HeroTitle.Text = $(if ($Mode -eq 'Wipe') { "Clearing verified media.`nNothing else moves." } else { 'Ingesting your shoot.' })
    $TopStatus.Text = $(if ($Mode -eq 'Wipe') { 'SAFE ERASE ACTIVE' } else { 'TRANSFER ACTIVE' })
    $StatusDot.Fill = '#FF3B30'
    Add-Activity $(if ($Mode -eq 'Wipe') { 'Re-verifying card media before erase.' } else { "Transfer started from $($script:CurrentCard.Root)" })
}

function Complete-Worker {
    if ($null -eq $script:Worker) { return }
    $mode = $script:WorkerMode
    $state = $script:WorkerState
    try { [void]$script:Worker.PowerShell.EndInvoke($script:Worker.Handle) } catch {}
    $script:Worker.PowerShell.Dispose()
    $manifestPath = $script:Worker.ManifestPath
    $script:Worker = $null
    $CancelButton.Visibility = 'Collapsed'
    $TransferButton.IsEnabled = $true
    if ($state.Success) {
        $TransferProgress.Value = 100
        $PercentText.Text = '100%'
        $TopStatus.Text = $state.Status
        $StatusDot.Fill = '#67D391'
        if ($mode -eq 'Transfer') {
            $script:LatestManifest = $manifestPath
            $WipeButton.IsEnabled = $true
            $HeroTitle.Text = "Transfer verified.`nYour originals are safe."
            $WipeDescription.Text = 'Erase is unlocked for the verified media in this session.'
            $LastRunText.Text = ("{0} copied / {1} already safe`n{2} verified" -f $state.CopiedCount, $state.SkippedCount, (Format-Bytes $state.TotalBytes))
            Show-Notification 'Transfer verified' ("{0} media files are safe in Camera." -f $state.TotalFiles)
        }
        else {
            $WipeButton.IsEnabled = $false
            $HeroTitle.Text = "Card media cleared.`nReady for the next shoot."
            $WipeDescription.Text = 'Verified media was erased. The camera folder structure was preserved.'
            Show-Notification 'Card media erased' ("{0} verified files were removed safely." -f $state.WipedCount)
        }
        Add-Activity $state.Status
    }
    else {
        $TopStatus.Text = $state.Status
        $StatusDot.Fill = '#FFB24A'
        $HeroTitle.Text = "Transfer paused.`nYour files are untouched."
        $HeroSubtitle.Text = $state.Error
        Add-Activity $state.Error
        Show-Notification 'Media Shuttle needs attention' $state.Error
    }
}

function Show-EraseConfirmation {
    if ([string]::IsNullOrWhiteSpace($script:LatestManifest) -or -not [IO.File]::Exists($script:LatestManifest)) { return $false }
    $confirmXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm safe erase" Width="480" Height="420" WindowStartupLocation="CenterOwner" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" FontFamily="Segoe UI">
  <Border CornerRadius="16" Background="#121318" BorderBrush="#41434A" BorderThickness="1" Padding="30">
    <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <StackPanel>
        <TextBlock Text="SAFE ERASE / FINAL CHECK" FontFamily="Consolas" FontSize="10" Foreground="#FF5A51"/>
        <TextBlock Text="Erase verified media?" Foreground="#F3F1EC" FontSize="27" FontWeight="SemiBold" Margin="0,12,0,0"/>
        <TextBlock Text="Only files matched to the completed SHA-256 transfer will be removed. Sony card folders and unverified files remain. This cannot be undone." Foreground="#A4A6AD" FontSize="12" LineHeight="19" TextWrapping="Wrap" Margin="0,14,0,22"/>
        <TextBlock Text="TYPE ERASE TO CONTINUE" FontFamily="Consolas" FontSize="9" Foreground="#777981"/>
        <TextBox x:Name="Phrase" Height="42" Margin="0,8,0,16" Background="#0B0C0F" Foreground="White" BorderBrush="#3B3D44" BorderThickness="1" Padding="12,9" FontFamily="Consolas" FontSize="13"/>
        <CheckBox x:Name="Acknowledge" Foreground="#D8D6D1" Content="I understand this deletes the verified originals from the card." FontSize="12"/>
      </StackPanel>
      <Grid Grid.Row="2" Margin="0,24,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Button x:Name="Cancel" Content="CANCEL" Height="44" Margin="0,0,6,0" Background="#1B1D22" Foreground="White" BorderBrush="#383A42"/>
        <Button x:Name="Erase" Grid.Column="1" Content="ERASE MEDIA" Height="44" Margin="6,0,0,0" Background="#FF3B30" Foreground="White" BorderBrush="#FF3B30" IsEnabled="False"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Parse($confirmXaml)
    $dialog.Owner = $window
    $phrase = $dialog.FindName('Phrase')
    $ack = $dialog.FindName('Acknowledge')
    $erase = $dialog.FindName('Erase')
    $cancel = $dialog.FindName('Cancel')
    $script:EraseConfirmed = $false
    $validate = {
        $erase.IsEnabled = (($phrase.Text.Trim().ToUpperInvariant() -eq 'ERASE') -and ($ack.IsChecked -eq $true))
    }
    $phrase.add_TextChanged($validate)
    $ack.add_Checked($validate)
    $ack.add_Unchecked($validate)
    $cancel.add_Click({ $dialog.Close() })
    $erase.add_Click({ $script:EraseConfirmed = $true; $dialog.Close() })
    [void]$dialog.ShowDialog()
    return $script:EraseConfirmed
}

function Update-LastRun {
    try {
        $latest = Get-ChildItem -LiteralPath $sessionsRoot -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latest) {
            $record = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json
            $LastRunText.Text = ("{0} / {1} files`n{2}" -f ([DateTime]$record.Completed).ToString('MMM d, h:mm tt'), $record.TotalFiles, $record.Status)
            if ($record.Status -eq 'Verified' -and [IO.Directory]::Exists($record.SourceRoot)) {
                $script:LatestManifest = $latest.FullName
            }
        }
    }
    catch {}
}

$script:TrayIcon = New-Object Windows.Forms.NotifyIcon
$script:TrayIcon.Text = 'Sony Media Shuttle'
$script:TrayIcon.Icon = [Drawing.SystemIcons]::Information
$script:TrayIcon.Visible = $true
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$openMenuItem = $trayMenu.Items.Add('Open Media Shuttle')
$openDestinationItem = $trayMenu.Items.Add('Open Camera folder')
[void]$trayMenu.Items.Add('-')
$exitMenuItem = $trayMenu.Items.Add('Exit')
$script:TrayIcon.ContextMenuStrip = $trayMenu

$openWindowAction = {
    $window.Show()
    $window.WindowState = 'Normal'
    [void]$window.Activate()
}
$openMenuItem.add_Click($openWindowAction)
$script:TrayIcon.add_DoubleClick($openWindowAction)
$openDestinationItem.add_Click({ Start-Process explorer.exe -ArgumentList @($DataRoot) })
$exitMenuItem.add_Click({
    if ($null -ne $script:Worker) {
        $answer = [Windows.MessageBox]::Show('A card operation is active. Cancel it and exit?', 'Exit Media Shuttle', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $script:WorkerState.CancelRequested = $true
    }
    $script:AllowExit = $true
    $window.Close()
})

$TitleBar.add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
$MinimizeButton.add_Click({ $window.WindowState = 'Minimized' })
$CloseButton.add_Click({ $window.Hide(); Show-Notification 'Media Shuttle is still watching' 'It will open automatically when a camera card appears.' })
$SettingsButton.add_Click({ $SettingsOverlay.Visibility = 'Visible' })
$CloseSettingsButton.add_Click({ $SettingsOverlay.Visibility = 'Collapsed' })
$DoneSettingsButton.add_Click({ $SettingsOverlay.Visibility = 'Collapsed' })
$OpenFolderButton.add_Click({ Start-Process explorer.exe -ArgumentList @($DataRoot) })
$TransferButton.add_Click({
    if ($null -eq $script:CurrentCard) {
        Add-Activity 'Manual scan requested.'
        $cards = @(Get-CardCandidates)
        if ($cards.Count -gt 0) { Update-CardSummary $cards[0]; Start-BackgroundWorker 'Transfer' '' }
        else { Add-Activity 'No camera-style media found.' }
    }
    else { Start-BackgroundWorker 'Transfer' '' }
})
$CancelButton.add_Click({ if ($null -ne $script:WorkerState) { $script:WorkerState.CancelRequested = $true; $CancelButton.IsEnabled = $false; Add-Activity 'Cancellation requested; finishing the current block.' } })
$WipeButton.add_Click({ if (Show-EraseConfirmation) { Start-BackgroundWorker 'Wipe' $script:LatestManifest } })

$AutoTransferCheck.add_Click({
    if (-not $script:SettingsReady) { return }
    $script:Settings.AutoTransfer = [bool]$AutoTransferCheck.IsChecked
    Save-Settings
})
$GroupByDateCheck.add_Click({
    if (-not $script:SettingsReady) { return }
    $script:Settings.GroupByDate = [bool]$GroupByDateCheck.IsChecked
    Save-Settings
})
$NotificationsCheck.add_Click({
    if (-not $script:SettingsReady) { return }
    $script:Settings.Notifications = [bool]$NotificationsCheck.IsChecked
    Save-Settings
})
$StartupCheck.add_Click({
    if (-not $script:SettingsReady) { return }
    try { Set-StartWithWindows ([bool]$StartupCheck.IsChecked); Add-Activity $(if ($StartupCheck.IsChecked) { 'Windows startup enabled.' } else { 'Windows startup disabled.' }) }
    catch { $StartupCheck.IsChecked = -not $StartupCheck.IsChecked; Add-Activity ('Startup setting failed: ' + $_.Exception.Message) }
})

$window.add_Closing({
    param($sender, $eventArgs)
    if (-not $script:AllowExit) {
        $eventArgs.Cancel = $true
        $window.Hide()
        return
    }
    $script:DriveTimer.Stop()
    $script:UiTimer.Stop()
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    if ($null -ne $mutex) { try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {} }
})

$script:UiTimer = New-Object Windows.Threading.DispatcherTimer
$script:UiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:UiTimer.add_Tick({
    if ($null -eq $script:Worker) { return }
    $state = $script:WorkerState
    $PhaseText.Text = [string]$state.Phase
    $CurrentFileText.Text = $(if ([string]::IsNullOrWhiteSpace([string]$state.CurrentFile)) { 'Preparing operation' } else { [string]$state.CurrentFile })
    $CopiedText.Text = "$($state.CopiedCount) files"
    $SkippedText.Text = "$($state.SkippedCount) files"
    $ProcessedText.Text = Format-Bytes ([long]$state.ProcessedBytes)
    if ([int]$state.TotalFiles -gt 0) { $AssetCount.Text = [string]$state.TotalFiles }
    if ([long]$state.TotalBytes -gt 0) { $MediaSize.Text = Format-Bytes ([long]$state.TotalBytes) }
    $percent = 0
    if ([long]$state.TotalBytes -gt 0) { $percent = [math]::Min(100, [math]::Round(([double]$state.ProcessedBytes / [double]$state.TotalBytes) * 100)) }
    $TransferProgress.Value = $percent
    $PercentText.Text = "$percent%"
    $logLine = $null
    while ($script:LogQueue.TryDequeue([ref]$logLine)) { Add-Activity $logLine.Substring(10) }
    if ($state.Done -and $script:Worker.Handle.IsCompleted) { Complete-Worker }
})

$script:DriveTimer = New-Object Windows.Threading.DispatcherTimer
$script:DriveTimer.Interval = [TimeSpan]::FromSeconds(2)
function Invoke-CardScan {
    try {
        $cards = @(Get-CardCandidates)
        $currentRoots = @{}
        foreach ($card in $cards) { $currentRoots[$card.Root] = $true }
        foreach ($knownRoot in @($script:SeenCards.Keys)) {
            if (-not $currentRoots.ContainsKey($knownRoot)) { $script:SeenCards.Remove($knownRoot) }
        }
        if ($cards.Count -eq 0) {
            if ($null -eq $script:Worker) { Update-CardSummary $null }
            return
        }
        $card = $cards[0]
        $isNew = -not $script:SeenCards.ContainsKey($card.Root)
        Update-CardSummary $card
        if ($isNew) {
            $script:SeenCards[$card.Root] = $true
            Add-Activity ("Detected $($card.Label) at $($card.Root)")
            if ($Background) { $window.Show(); $window.WindowState = 'Normal'; [void]$window.Activate() }
            if ($script:Settings.AutoTransfer -and $null -eq $script:Worker) { Start-BackgroundWorker 'Transfer' '' }
        }
    }
    catch {
        Add-Activity ('Card scan error: ' + $_.Exception.Message)
    }
}
$script:DriveTimer.add_Tick({ Invoke-CardScan })

Update-LastRun
Add-Activity 'System armed and watching for camera media.'

if (-not [string]::IsNullOrWhiteSpace($RenderPreview)) {
    $previewCard = [pscustomobject]@{ Root = 'F:\'; Label = 'LEXAR'; TotalSize = 256GB; FreeSpace = 239GB; DriveType = 'Removable' }
    Update-CardSummary $previewCard
    $AssetCount.Text = '481'
    $MediaSize.Text = '17.1 GB'
    $PhaseText.Text = 'COPYING + VERIFYING'
    $CurrentFileText.Text = 'DSC00482.ARW'
    $TransferProgress.Value = 68
    $PercentText.Text = '68%'
    $CopiedText.Text = '329 files'
    $SkippedText.Text = '0 files'
    $ProcessedText.Text = '11.6 GB'
    $HeroTitle.Text = 'Ingesting your shoot.'
    $TransferButton.IsEnabled = $false
    $CancelButton.Visibility = 'Visible'
    $window.Show()
    $window.UpdateLayout()
    $width = [int][math]::Ceiling($window.ActualWidth)
    $height = [int][math]::Ceiling($window.ActualHeight)
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $previewDirectory = Split-Path -Parent $RenderPreview
    if (-not [string]::IsNullOrWhiteSpace($previewDirectory) -and -not [IO.Directory]::Exists($previewDirectory)) { [void][IO.Directory]::CreateDirectory($previewDirectory) }
    $stream = New-Object IO.FileStream($RenderPreview, [IO.FileMode]::Create)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $script:AllowExit = $true
    $window.Close()
    exit 0
}

$window.add_Loaded({
    $script:UiTimer.Start()
    $script:DriveTimer.Start()
    Invoke-CardScan
    if ($Background -and $null -eq $script:CurrentCard) { $window.Hide() }
})

[void]$window.ShowDialog()
