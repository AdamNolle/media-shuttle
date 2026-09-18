using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using MediaShuttle.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.UI;

namespace MediaShuttle;

public sealed partial class MainWindow : Window
{
    private readonly bool _launchInBackground;
    private string _destinationRoot;
    private readonly StateStore _stateStore;
    private readonly AppLogger _logger;
    private readonly TransferService _transferService;
    private readonly WipeService _wipeService;
    private readonly ObservableCollection<string> _activity = [];
    private readonly HashSet<string> _seenCards = new(StringComparer.OrdinalIgnoreCase);
    private readonly DispatcherQueueTimer _scanTimer;
    private readonly TrayIconService _trayIcon;
    private readonly AppWindow _appWindow;
    private AppSettings _settings = new();
    private CardInfo? _currentCard;
    private TransferSession? _verifiedSession;
    private CancellationTokenSource? _operationCancellation;
    private bool _settingsReady;
    private bool _scanInProgress;
    private bool _busy;
    private bool _destinationAvailable = true;
    private int _lastScannedMediaCount = -1;
    private bool _allowClose;

    public MainWindow(bool launchInBackground)
    {
        _launchInBackground = launchInBackground;
        _destinationRoot = DefaultDestinationRoot();
        string stateRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Media Shuttle");
        _stateStore = new StateStore(stateRoot);
        _logger = new AppLogger(stateRoot);
        _transferService = new TransferService(_stateStore, _logger);
        _wipeService = new WipeService(_stateStore, _logger);

        InitializeComponent();
        Title = "Media Shuttle";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        try
        {
            SystemBackdrop = new MicaBackdrop();
        }
        catch
        {
            SystemBackdrop = new DesktopAcrylicBackdrop();
        }

        IntPtr windowHandle = WindowNative.GetWindowHandle(this);
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(windowHandle));
        _appWindow.Title = "Media Shuttle";
        SizeAndCenterWindow(windowHandle);
        _appWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "MediaShuttle.ico");
        if (File.Exists(iconPath))
        {
            _appWindow.SetIcon(iconPath);
        }

        _appWindow.Closing += OnAppWindowClosing;
        DestinationText.Text = _destinationRoot;
        DestinationText.SetValue(ToolTipService.ToolTipProperty, _destinationRoot);
        ActivityList.ItemsSource = _activity;

        OpenFolderButton.Click += (_, _) => OpenDestinationFolder();
        ChangeDestinationButton.Click += async (_, _) => await ChooseDestinationAsync();
        TransferButton.Click += async (_, _) => await StartTransferAsync();
        CancelButton.Click += (_, _) =>
        {
            _operationCancellation?.Cancel();
            CancelButton.IsEnabled = false;
            AddActivity("Cancellation requested. The current block will finish safely.");
        };
        WipeButton.Click += async (_, _) => await ConfirmAndWipeAsync();
        AutoTransferToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        GroupByDateToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        NotificationsToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        StartupToggle.Toggled += async (_, _) => await UpdateStartupAsync();
        ThemeComboBox.SelectionChanged += async (_, _) => await UpdateThemeAsync();

        _scanTimer = DispatcherQueue.CreateTimer();
        _scanTimer.Interval = TimeSpan.FromSeconds(2);
        _scanTimer.Tick += async (_, _) => await ScanCardsAsync();

        _trayIcon = new TrayIconService(
            windowHandle,
            iconPath,
            () => DispatcherQueue.TryEnqueue(ShowWindow),
            () => DispatcherQueue.TryEnqueue(OpenDestinationFolder),
            () => DispatcherQueue.TryEnqueue(ExitApplication));
        Root.Loaded += async (_, _) => await InitializeAsync();
    }

    private void SizeAndCenterWindow(IntPtr windowHandle)
    {
        uint dpi = NativeMethods.GetDpiForWindow(windowHandle);
        double scale = Math.Max(1.0, dpi / 96.0);
        DisplayArea displayArea = DisplayArea.GetFromWindowId(_appWindow.Id, DisplayAreaFallback.Primary);
        RectInt32 workArea = displayArea.WorkArea;

        int edgeMargin = (int)Math.Round(24 * scale);
        int maximumWidth = Math.Max(720, workArea.Width - edgeMargin * 2);
        int maximumHeight = Math.Max(560, workArea.Height - edgeMargin * 2);
        int width = Math.Min((int)Math.Round(1180 * scale), maximumWidth);
        int height = Math.Min((int)Math.Round(720 * scale), maximumHeight);
        int x = workArea.X + Math.Max(0, (workArea.Width - width) / 2);
        int y = workArea.Y + Math.Max(0, (workArea.Height - height) / 2);

        _appWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private async Task InitializeAsync()
    {
        _settings = await _stateStore.LoadSettingsAsync();
        if (!string.IsNullOrWhiteSpace(_settings.DestinationRoot))
        {
            try
            {
                _destinationRoot = Path.GetFullPath(_settings.DestinationRoot);
            }
            catch
            {
                _destinationRoot = DefaultDestinationRoot();
            }
        }

        Exception? destinationError = null;
        try
        {
            EnsureDestinationFolders(_destinationRoot);
        }
        catch (Exception exception) when (IsDestinationException(exception))
        {
            _destinationAvailable = false;
            destinationError = exception;
        }

        UpdateDestinationDisplay();
        OpenFolderButton.IsEnabled = _destinationAvailable;
        AutoTransferToggle.IsOn = _settings.AutoTransfer;
        GroupByDateToggle.IsOn = _settings.GroupByDate;
        NotificationsToggle.IsOn = _settings.ShowNotifications;
        StartupToggle.IsOn = StartupService.IsEnabled;
        ThemeComboBox.SelectedIndex = _settings.Theme switch
        {
            "Light" => 1,
            "Dark" => 2,
            _ => 0
        };
        ApplyTheme(_settings.Theme);
        if (_destinationAvailable)
        {
            _settings.DestinationRoot = _destinationRoot;
            await _stateStore.SaveSettingsAsync(_settings);
        }
        _settingsReady = true;
        AddActivity("Watcher ready. Removable-media and volume identity checks active.");
        _scanTimer.Start();
        await ScanCardsAsync();

        if (destinationError is not null)
        {
            ShowError(
                "Destination unavailable",
                "The saved destination could not be opened. Choose an available folder before transferring.");
            AddActivity("Saved destination unavailable: " + destinationError.Message);
            SetTopStatus("Choose a destination", Color.FromArgb(255, 196, 43, 43));
        }

        if (_launchInBackground && _currentCard is null && _destinationAvailable)
        {
            _appWindow.Hide();
        }
    }

    private async Task ScanCardsAsync()
    {
        if (_busy || _scanInProgress)
        {
            return;
        }

        _scanInProgress = true;
        try
        {
            IReadOnlyList<CardInfo> cards = await Task.Run(() => CardDetector.GetCandidates(_destinationRoot));
            var activeRoots = cards.Select(card => card.RootPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
            _seenCards.RemoveWhere(root => !activeRoots.Contains(root));
            if (cards.Count == 0)
            {
                _currentCard = null;
                _verifiedSession = null;
                _lastScannedMediaCount = -1;
                UpdateDisconnectedState();
                return;
            }

            CardInfo card = cards[0];
            bool isNew = _seenCards.Add(card.RootPath);
            bool cardChanged = _currentCard is null ||
                               !_currentCard.RootPath.Equals(card.RootPath, StringComparison.OrdinalIgnoreCase);
            TransferSession? previousSession = _verifiedSession;
            int previousMediaCount = _lastScannedMediaCount;

            _currentCard = card;
            IReadOnlyList<MediaItem> media = await Task.Run(() => MediaClassifier.Scan(card.RootPath));
            _lastScannedMediaCount = media.Count;
            AssetCountText.Text = media.Count.ToString("N0");
            MediaSizeText.Text = FormatBytes(media.Sum(item => item.Size));
            _verifiedSession = await _stateStore.LoadLatestVerifiedForCardAsync(card);

            bool canWipe = _verifiedSession is { Files.Count: > 0 };
            bool verificationChanged = previousSession?.SessionId != _verifiedSession?.SessionId;
            WipeButton.IsEnabled = canWipe;
            if (cardChanged || previousMediaCount != media.Count || verificationChanged)
            {
                if (media.Count == 0)
                {
                    UpdateEmptyCardState(card, canWipe);
                }
                else if (canWipe)
                {
                    UpdateVerifiedState(card, _verifiedSession!);
                }
                else
                {
                    UpdateDetectedState(card);
                }
            }

            if (isNew)
            {
                AddActivity($"Detected {card.VolumeLabel} at {card.RootPath}");
                if (_launchInBackground)
                {
                    ShowWindow();
                }
                if (_settings.AutoTransfer && _destinationAvailable && media.Count > 0)
                {
                    await StartTransferAsync();
                }
            }
        }
        catch (Exception exception)
        {
            ShowError("Card scan failed", exception.Message);
            await _logger.WriteAsync("Card scan failed: " + exception);
        }
        finally
        {
            _scanInProgress = false;
        }
    }

    private async Task StartTransferAsync()
    {
        if (_busy)
        {
            return;
        }
        if (!_destinationAvailable)
        {
            ShowError("Choose a destination", "Select an available destination folder before transferring.");
            return;
        }
        if (_currentCard is null)
        {
            await ScanCardsAsync();
            if (_currentCard is null)
            {
                ShowMessage(
                    "No camera card found",
                    "Connect a removable card containing DCIM, M4ROOT, or PRIVATE folders.",
                    InfoBarSeverity.Informational);
                return;
            }
        }
        if (_lastScannedMediaCount == 0)
        {
            ShowMessage(
                "No supported media found",
                "This card does not currently contain supported photos or videos.",
                InfoBarSeverity.Informational);
            return;
        }

        _busy = true;
        _operationCancellation = new CancellationTokenSource();
        StatusInfoBar.IsOpen = false;
        SetOperationControls(true, allowCancel: true);
        HeroTitleText.Text = "Copying and verifying your media.";
        HeroSubtitleText.Text = "Each file is written safely, checked with SHA-256, then made visible at the destination.";
        SetTopStatus("Transfer active", Color.FromArgb(255, 255, 77, 68));
        AddActivity($"Transfer started from {_currentCard.RootPath}");

        try
        {
            var progress = new Progress<OperationProgress>(UpdateProgress);
            TransferResult result = await _transferService.TransferAsync(
                _currentCard,
                _destinationRoot,
                _settings.GroupByDate,
                progress,
                _operationCancellation.Token);
            _verifiedSession = result.Session;
            WipeButton.IsEnabled = true;
            WipeDescriptionText.Text = "Unlocked. Every remaining media file has a verified destination copy.";
            HeroTitleText.Text = "Transfer verified.";
            HeroSubtitleText.Text =
                $"{result.Session.TotalFiles:N0} files are verified at the selected destination. The card can now be erased.";
            SetTopStatus("Transfer verified", Color.FromArgb(255, 56, 166, 92));
            AddActivity(
                $"Verified {result.Session.TotalFiles:N0} files — " +
                $"{result.Session.CopiedCount:N0} copied, {result.Session.SkippedCount:N0} already safe.");
            ShowNotification(
                "Transfer verified",
                $"{result.Session.TotalFiles:N0} files are verified at the selected destination.");
            ShowMessage(
                "Transfer verified",
                "Every remaining media file matches its destination copy.",
                InfoBarSeverity.Success);
        }
        catch (OperationCanceledException)
        {
            PhaseText.Text = "CANCELLED";
            AddActivity("Transfer cancelled. Completed files remain safe; temporary files were removed.");
            SetTopStatus("Transfer cancelled", Color.FromArgb(255, 202, 139, 39));
            ShowMessage(
                "Transfer cancelled",
                "Completed destination files were kept and temporary files were removed.",
                InfoBarSeverity.Warning);
        }
        catch (Exception exception)
        {
            PhaseText.Text = "NEEDS ATTENTION";
            ShowError("Transfer failed", exception.Message);
            AddActivity("Transfer failed: " + exception.Message);
            await _logger.WriteAsync("Transfer failed: " + exception);
            SetTopStatus("Needs attention", Color.FromArgb(255, 196, 43, 43));
        }
        finally
        {
            TransferProgress.IsIndeterminate = false;
            _operationCancellation.Dispose();
            _operationCancellation = null;
            _busy = false;
            SetOperationControls(false, allowCancel: false);
        }
    }

    private async Task ConfirmAndWipeAsync()
    {
        if (_busy || _currentCard is null || _verifiedSession is null)
        {
            return;
        }

        var phrase = new TextBox
        {
            Header = "Type ERASE EVERYTHING to continue",
            PlaceholderText = "ERASE EVERYTHING"
        };
        var acknowledge = new CheckBox
        {
            Content = $"I understand this removes all files and folders from {_currentCard.RootPath}."
        };
        var content = new StackPanel { Spacing = 14 };
        content.Children.Add(new TextBlock
        {
            Text =
                "Media Shuttle will re-verify every remaining media file against its destination copy. " +
                "It will then remove all card content, including camera databases and non-media files. " +
                "Windows-managed volume folders may be recreated automatically.",
            TextWrapping = TextWrapping.Wrap
        });
        content.Children.Add(phrase);
        content.Children.Add(acknowledge);

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Erase everything on card?",
            Content = content,
            PrimaryButtonText = "Erase card contents",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false
        };
        void Validate(object? sender, object args) =>
            dialog.IsPrimaryButtonEnabled =
                phrase.Text.Trim().Equals("ERASE EVERYTHING", StringComparison.Ordinal) &&
                acknowledge.IsChecked == true;
        phrase.TextChanged += Validate;
        acknowledge.Checked += Validate;
        acknowledge.Unchecked += Validate;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        _busy = true;
        StatusInfoBar.IsOpen = false;
        SetOperationControls(true, allowCancel: false);
        WipeButton.IsEnabled = false;
        HeroTitleText.Text = "Re-verifying before erase.";
        HeroSubtitleText.Text = "Deletion starts only after every remaining media file matches its destination copy.";
        SetTopStatus("Erase active", Color.FromArgb(255, 255, 77, 68));
        AddActivity("Erase approved. Re-verifying card media before deletion.");

        try
        {
            var progress = new Progress<OperationProgress>(UpdateProgress);
            WipeResult result = await _wipeService.WipeEverythingAsync(
                _currentCard,
                _verifiedSession,
                progress,
                CancellationToken.None);
            _verifiedSession = null;
            _lastScannedMediaCount = 0;
            HeroTitleText.Text = "Card contents erased.";
            HeroSubtitleText.Text =
                "The post-erase scan found no remaining media or user content. The card is ready for the camera.";
            TransferButton.Content = "No media found";
            WipeDescriptionText.Text = "Erase complete. Connect another card or use this card in your camera.";
            SetTopStatus("Card empty", Color.FromArgb(255, 56, 166, 92));
            AddActivity($"Erase complete. {result.DeletedFiles:N0} files removed; post-erase scan empty.");
            ShowNotification("Card contents erased", $"{result.DeletedFiles:N0} files removed successfully.");
            ShowMessage(
                "Card contents erased",
                "The post-erase verification found no remaining media or user content.",
                InfoBarSeverity.Success);
        }
        catch (Exception exception)
        {
            ShowError("Card erase did not complete", exception.Message);
            AddActivity("Erase stopped: " + exception.Message);
            await _logger.WriteAsync("Card erase failed: " + exception);
            SetTopStatus("Erase needs attention", Color.FromArgb(255, 196, 43, 43));
            WipeButton.IsEnabled = _verifiedSession is not null;
        }
        finally
        {
            _busy = false;
            SetOperationControls(false, allowCancel: false);
        }
    }

    private void UpdateProgress(OperationProgress progress)
    {
        TransferProgress.IsIndeterminate = progress.Phase == OperationPhase.Scanning;
        PhaseText.Text = progress.Phase switch
        {
            OperationPhase.CheckingDuplicate => "CHECKING DUPLICATE",
            OperationPhase.ReVerifying => "RE-VERIFYING",
            OperationPhase.Erasing => "ERASING CONTENTS",
            _ => progress.Phase.ToString().ToUpperInvariant()
        };
        CurrentFileText.Text = progress.CurrentItem;
        TransferProgress.Value = progress.Percent;
        PercentText.Text = $"{progress.Percent:0}%";
        CopiedText.Text = $"{progress.CopiedFiles:N0} files";
        SkippedText.Text = $"{progress.SkippedFiles:N0} files";
        ProcessedText.Text = FormatBytes(progress.ProcessedBytes);
    }

    private async Task SaveSettingsFromControlsAsync()
    {
        if (!_settingsReady)
        {
            return;
        }
        _settings.AutoTransfer = AutoTransferToggle.IsOn;
        _settings.GroupByDate = GroupByDateToggle.IsOn;
        _settings.ShowNotifications = NotificationsToggle.IsOn;
        _settings.DestinationRoot = _destinationRoot;
        await _stateStore.SaveSettingsAsync(_settings);
    }

    private async Task UpdateStartupAsync()
    {
        if (!_settingsReady)
        {
            return;
        }
        try
        {
            StartupService.SetEnabled(StartupToggle.IsOn);
            AddActivity(StartupToggle.IsOn ? "Windows startup enabled." : "Windows startup disabled.");
        }
        catch (Exception exception)
        {
            _settingsReady = false;
            StartupToggle.IsOn = !StartupToggle.IsOn;
            _settingsReady = true;
            ShowError("Startup setting failed", exception.Message);
        }
        await SaveSettingsFromControlsAsync();
    }

    private void UpdateDetectedState(CardInfo card)
    {
        UpdateCardSummary(card);
        HeroTitleText.Text = "Card detected.";
        HeroSubtitleText.Text = "Ready to sort and verify the supported media at your selected destination.";
        TransferButton.Content = "Transfer + verify";
        TransferButton.IsEnabled = !_busy && _destinationAvailable;
        WipeDescriptionText.Text = "Locked until every remaining media file has a verified destination copy.";
        SetTopStatus("Media detected", Color.FromArgb(255, 255, 77, 68));
    }

    private void UpdateVerifiedState(CardInfo card, TransferSession session)
    {
        UpdateCardSummary(card);
        HeroTitleText.Text = "Transfer already verified.";
        HeroSubtitleText.Text =
            $"{session.TotalFiles:N0} files have verified destination copies. You can transfer again or erase the card.";
        TransferButton.Content = "Transfer again";
        TransferButton.IsEnabled = !_busy && _destinationAvailable;
        WipeDescriptionText.Text = "Unlocked. Every remaining media file has a verified destination copy.";
        SetTopStatus("Transfer verified", Color.FromArgb(255, 56, 166, 92));
    }

    private void UpdateEmptyCardState(CardInfo card, bool canWipe)
    {
        UpdateCardSummary(card);
        HeroTitleText.Text = "No supported media found.";
        HeroSubtitleText.Text = canWipe
            ? "No camera media remains. Verified transfer history still protects the erase action."
            : "The connected card does not currently contain supported photos or videos.";
        TransferButton.Content = "No media found";
        TransferButton.IsEnabled = false;
        WipeDescriptionText.Text = canWipe
            ? "Unlocked. No supported media remains to re-verify."
            : "Locked until a transfer completes and every media file is verified.";
        SetTopStatus(
            canWipe ? "Transfer verified" : "Card empty",
            canWipe ? Color.FromArgb(255, 56, 166, 92) : Color.FromArgb(255, 124, 124, 124));
    }

    private void UpdateCardSummary(CardInfo card)
    {
        CardLabelText.Text = card.VolumeLabel;
        CardDetailText.Text = $"{card.RootPath}  •  Removable media";
    }

    private void UpdateDisconnectedState()
    {
        CardLabelText.Text = "No card connected";
        CardDetailText.Text = "Insert a removable camera card to begin.";
        AssetCountText.Text = "—";
        MediaSizeText.Text = "—";
        HeroTitleText.Text = "Ready for your next card.";
        HeroSubtitleText.Text =
            "JPEGs, RAWs, and video are sorted automatically. Every media file is SHA-256 verified before erase is available.";
        TransferButton.Content = "Scan for media";
        TransferButton.IsEnabled = !_busy && _destinationAvailable;
        WipeButton.IsEnabled = false;
        WipeDescriptionText.Text = "Locked until every remaining media file has a verified destination copy.";
        SetTopStatus("Waiting for media", Color.FromArgb(255, 124, 124, 124));
    }


    private void SetOperationControls(bool active, bool allowCancel)
    {
        TransferButton.IsEnabled =
            !active && _destinationAvailable && _lastScannedMediaCount != 0;
        CancelButton.Visibility = active && allowCancel ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.IsEnabled = active && allowCancel;
        AutoTransferToggle.IsEnabled = !active;
        GroupByDateToggle.IsEnabled = !active;
        NotificationsToggle.IsEnabled = !active;
        StartupToggle.IsEnabled = !active;
        ChangeDestinationButton.IsEnabled = !active;
        OpenFolderButton.IsEnabled = !active && _destinationAvailable;
        ThemeComboBox.IsEnabled = !active;
        SettingsButton.IsEnabled = !active;
    }

    private void SetTopStatus(string text, Color color)
    {
        TopStatusText.Text = text;
        StatusDot.Fill = new SolidColorBrush(color);
    }

    private void ShowMessage(string title, string message, InfoBarSeverity severity)
    {
        StatusInfoBar.Title = title;
        StatusInfoBar.Message = message;
        StatusInfoBar.Severity = severity;
        StatusInfoBar.IsOpen = true;
    }

    private void ShowError(string title, string message) => ShowMessage(title, message, InfoBarSeverity.Error);

    private void AddActivity(string message)
    {
        _activity.Insert(0, $"{DateTime.Now:HH:mm:ss}  {message}");
        while (_activity.Count > 6)
        {
            _activity.RemoveAt(_activity.Count - 1);
        }
    }

    private async Task ChooseDestinationAsync()
    {
        if (_busy)
        {
            return;
        }

        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.Desktop
        };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        Windows.Storage.StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (folder is null || string.IsNullOrWhiteSpace(folder.Path))
        {
            return;
        }

        string selectedPath;
        try
        {
            selectedPath = Path.GetFullPath(folder.Path);
        }
        catch (Exception exception) when (IsDestinationException(exception) || exception is ArgumentException)
        {
            ShowError("Destination unavailable", exception.Message);
            return;
        }

        if (_currentCard is not null && IsSameOrChild(selectedPath, _currentCard.RootPath))
        {
            ShowError("Choose a different destination", "The destination cannot be on the connected source card.");
            return;
        }

        if (Directory.Exists(Path.Combine(selectedPath, "DCIM")) ||
            Directory.Exists(Path.Combine(selectedPath, "M4ROOT")) ||
            Directory.Exists(Path.Combine(selectedPath, "PRIVATE")))
        {
            ShowError(
                "Choose a different destination",
                "That folder looks like a camera-card root. Choose a folder on the computer instead.");
            return;
        }

        try
        {
            EnsureDestinationFolders(selectedPath);
            _destinationRoot = selectedPath;
            _destinationAvailable = true;
            UpdateDestinationDisplay();
            OpenFolderButton.IsEnabled = true;
            _settings.DestinationRoot = _destinationRoot;
            await _stateStore.SaveSettingsAsync(_settings);
            _seenCards.Clear();
            AddActivity($"Destination changed to {_destinationRoot}");
            ShowMessage(
                "Destination updated",
                "New transfers will use the selected folder.",
                InfoBarSeverity.Success);
            await ScanCardsAsync();
        }
        catch (Exception exception) when (IsDestinationException(exception))
        {
            ShowError("Destination unavailable", exception.Message);
        }
    }

    private async Task UpdateThemeAsync()
    {
        if (!_settingsReady || ThemeComboBox.SelectedItem is not ComboBoxItem item)
        {
            return;
        }

        string theme = item.Tag?.ToString() ?? "System";
        _settings.Theme = theme;
        ApplyTheme(theme);
        await _stateStore.SaveSettingsAsync(_settings);
        AddActivity($"Appearance set to {item.Content}.");
    }

    private void ApplyTheme(string theme)
    {
        Root.RequestedTheme = theme switch
        {
            "Light" => ElementTheme.Light,
            "Dark" => ElementTheme.Dark,
            _ => ElementTheme.Default
        };
    }

    private static void EnsureDestinationFolders(string destinationRoot)
    {
        Directory.CreateDirectory(Path.Combine(destinationRoot, "Photos", "JPEGs"));
        Directory.CreateDirectory(Path.Combine(destinationRoot, "Photos", "RAWs"));
        Directory.CreateDirectory(Path.Combine(destinationRoot, "Photos", "Other"));
        Directory.CreateDirectory(Path.Combine(destinationRoot, "Videos"));
    }

    private static bool IsDestinationException(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or NotSupportedException;

    private void UpdateDestinationDisplay()
    {
        DestinationText.Text = _destinationRoot;
        DestinationText.SetValue(ToolTipService.ToolTipProperty, _destinationRoot);
    }

    private static string DefaultDestinationRoot() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Camera");

    private static bool IsSameOrChild(string candidate, string parent)
    {
        string normalizedCandidate = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar);
        string normalizedParent = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar);
        return normalizedCandidate.Equals(normalizedParent, StringComparison.OrdinalIgnoreCase) ||
               normalizedCandidate.StartsWith(normalizedParent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private void OpenDestinationFolder()
    {
        if (!_destinationAvailable)
        {
            ShowError("Destination unavailable", "Choose an available destination folder first.");
            return;
        }

        try
        {
            EnsureDestinationFolders(_destinationRoot);
            Process.Start(new ProcessStartInfo(_destinationRoot) { UseShellExecute = true });
        }
        catch (Exception exception) when (
            IsDestinationException(exception) || exception is Win32Exception)
        {
            _destinationAvailable = false;
            SetOperationControls(false, allowCancel: false);
            ShowError("Destination unavailable", exception.Message);
            AddActivity("Destination unavailable: " + exception.Message);
            SetTopStatus("Choose a destination", Color.FromArgb(255, 196, 43, 43));
        }
    }

    private void ShowWindow()
    {
        _appWindow.Show();
        Activate();
        NativeMethods.ActivateExistingWindow("Media Shuttle");
    }

    private void ExitApplication()
    {
        if (_busy)
        {
            ShowWindow();
            ShowMessage(
                "Operation in progress",
                "Wait for the current operation to finish, or cancel the transfer before exiting.",
                InfoBarSeverity.Warning);
            return;
        }

        _allowClose = true;
        _scanTimer.Stop();
        _trayIcon.Dispose();
        _appWindow.Destroy();
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose)
        {
            return;
        }
        args.Cancel = true;
        _appWindow.Hide();
        ShowNotification("Media Shuttle is still watching", "Double-click the tray icon to reopen the app.");
    }

    private void ShowNotification(string title, string message)
    {
        if (!_settings.ShowNotifications)
        {
            return;
        }
        _trayIcon.ShowNotification(title, message);
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = Math.Max(0, bytes);
        int unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0 ? $"{value:0} {units[unit]}" : $"{value:0.0} {units[unit]}";
    }
}
