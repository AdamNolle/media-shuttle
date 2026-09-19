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
    private const double ScanPulseWidthPercent = 16;
    private const double MinimumActivityHeight = 88;
    private const double MaximumActivityHeight = 460;
    private static readonly Color NeutralStatusColor = Color.FromArgb(255, 124, 124, 124);
    private static readonly Color ActiveStatusColor = Color.FromArgb(255, 255, 77, 68);
    private static readonly Color VerifiedStatusColor = Color.FromArgb(255, 56, 166, 92);
    private static readonly Color WarningStatusColor = Color.FromArgb(255, 202, 139, 39);
    private static readonly Color ErrorStatusColor = Color.FromArgb(255, 196, 43, 43);

    private readonly bool _launchInBackground;
    private string _destinationRoot;
    private readonly StateStore _stateStore;
    private readonly AppLogger _logger;
    private readonly TransferService _transferService;
    private readonly WipeService _wipeService;
    private readonly ObservableCollection<string> _activity = [];
    private readonly CardPresenceTracker _cardPresence = new();
    private readonly DispatcherQueueTimer _scanTimer;
    private readonly DispatcherQueueTimer _scanPulseTimer;
    private double _scanPulsePosition;
    private int _scanPulseDirection = 1;
    private readonly TrayIconService _trayIcon;
    private readonly AppWindow _appWindow;
    private readonly SolidColorBrush _progressFillActiveBrush = new(ActiveStatusColor);
    private readonly SolidColorBrush _progressFillCompleteBrush = new(VerifiedStatusColor);
    private AppSettings _settings = new();
    private CardInfo? _currentCard;
    private TransferSession? _verifiedSession;
    private CancellationTokenSource? _operationCancellation;
    private DateTimeOffset? _operationStartedUtc;
    private string? _lastSessionFilePath;
    private bool _settingsReady;
    private bool _scanInProgress;
    private bool _busy;
    private bool _destinationAvailable = true;
    private int _lastScannedMediaCount = -1;
    private int _unverifiableFileCount;
    private string? _lastScanSignature;
    private bool _allowClose;
    private bool _initialActivationHandled;
    private bool _placementPending;
    private readonly IntPtr _windowHandle;

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
        _windowHandle = windowHandle;
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(windowHandle));
        _appWindow.Title = "Media Shuttle";
        SizeAndCenterWindow(windowHandle);
        if (_launchInBackground)
        {
            // Activate() below shows the window, and the earliest we can hide it again is the
            // Activated handler one message-pump turn later — long enough for Windows to paint a
            // centred window and animate it in. Park it off the virtual screen until something
            // actually asks for it, so a boot launch shows nothing at all. ShowWindow() centres it
            // before the first real reveal.
            _placementPending = true;
            _appWindow.Move(new PointInt32(-30000, -30000));
        }
        _appWindow.Changed += (_, args) =>
        {
            if (args.DidSizeChange)
            {
                UpdateResponsiveLayout(windowHandle);
            }
        };
        UpdateResponsiveLayout(windowHandle);

        // AppWindow.Changed announces a resize before the content is laid out again, so the viewport
        // is still the old one there. This fires once the ScrollViewer has actually been given its
        // new size, and hands that size over directly.
        RootScrollViewer.SizeChanged += (_, args) => ApplyActivityListHeight(args.NewSize.Height);
        Root.ActualThemeChanged += (_, _) => UpdateTitleBarColors();
        UpdateTitleBarColors();
        string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "MediaShuttle.ico");
        if (File.Exists(iconPath))
        {
            _appWindow.SetIcon(iconPath);
        }

        _appWindow.Closing += OnAppWindowClosing;

        // A background launch (the Windows startup shortcut passes --background) still needs
        // Activate() called once — without it the root element never loads, so InitializeAsync
        // never runs and the app never scans for cards. Hiding only after InitializeAsync
        // finishes its awaits (settings load, destination checks, the first card scan) let the
        // window sit on screen for that whole stretch on every automatic boot launch. Hide it on
        // the very first Activated instead, which together with the off-screen parking above means
        // a background launch never puts anything on screen. Later activations (the user reopening
        // from the tray icon) are intentionally left alone.
        Activated += (_, _) =>
        {
            if (_initialActivationHandled)
            {
                return;
            }
            _initialActivationHandled = true;
            if (_launchInBackground)
            {
                _appWindow.Hide();
            }
        };

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
        ReportButton.Click += (_, _) => OpenSessionReport();
        SessionTransferAgainButton.Click += async (_, _) => await StartTransferAsync();
        AutoTransferToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        GroupByDateToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        NotificationsToggle.Toggled += async (_, _) => await SaveSettingsFromControlsAsync();
        ActivityToggle.Toggled += async (_, _) =>
        {
            ActivitySection.Visibility = ActivityToggle.IsOn ? Visibility.Visible : Visibility.Collapsed;
            ScheduleActivityListHeightUpdate();
            await SaveSettingsFromControlsAsync();
        };
        StartupToggle.Toggled += async (_, _) => await UpdateStartupAsync();
        ThemeComboBox.SelectionChanged += async (_, _) => await UpdateThemeAsync();

        _scanTimer = DispatcherQueue.CreateTimer();
        _scanTimer.Interval = TimeSpan.FromSeconds(2);
        _scanTimer.Tick += async (_, _) => await ScanCardsAsync();

        _scanPulseTimer = DispatcherQueue.CreateTimer();
        _scanPulseTimer.Interval = TimeSpan.FromMilliseconds(80);
        _scanPulseTimer.Tick += (_, _) => AdvanceScanPulse();

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

        // Windows otherwise lets the window be dragged down to a few dozen pixels, which no layout
        // survives. This is the narrowest the single-column arrangement still renders cleanly.
        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)Math.Round(420 * scale);
            presenter.PreferredMinimumHeight = (int)Math.Round(420 * scale);
        }

        int edgeMargin = (int)Math.Round(24 * scale);
        int maximumWidth = Math.Max(720, workArea.Width - edgeMargin * 2);
        int maximumHeight = Math.Max(560, workArea.Height - edgeMargin * 2);
        int width = Math.Min((int)Math.Round(1180 * scale), maximumWidth);
        int height = Math.Min((int)Math.Round(660 * scale), maximumHeight);
        int x = workArea.X + Math.Max(0, (workArea.Width - width) / 2);
        int y = workArea.Y + Math.Max(0, (workArea.Height - height) / 2);

        _appWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private void UpdateResponsiveLayout(IntPtr windowHandle)
    {
        double scale = Math.Max(1.0, NativeMethods.GetDpiForWindow(windowHandle) / 96.0);

        // This runs from AppWindow.Changed, which fires before the content is laid out again, so
        // the ScrollViewer's viewport still describes the previous size. The window is the only
        // measurement that is current here.
        double width = _appWindow.Size.Width / scale;
        bool narrow = width < 900;

        // ScrollViewer only constrains width along an axis it can scroll, so with horizontal
        // scrolling disabled it otherwise hands MainLayout unbounded width and its content never
        // wraps or reflows. Pin it to the window's actual content width so it, and everything
        // inside it, resizes as the window is resized.
        MainLayout.Width = Math.Max(0, width);

        SourceColumn.Width = narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(240);
        OperationsColumn.Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        Grid.SetColumn(SourcePanel, 0);
        Grid.SetRow(SourcePanel, 0);
        Grid.SetColumn(OperationsPanel, narrow ? 0 : 1);
        Grid.SetRow(OperationsPanel, narrow ? 1 : 0);
        MainLayout.ColumnSpacing = narrow ? 0 : 22;
        MainLayout.Padding = narrow ? new Thickness(16, 14, 16, 22) : new Thickness(24, 22, 24, 26);

        bool compactTitleBar = width < 760;
        bool iconOnlyTitleBar = width < 520;
        StatusPill.Visibility = compactTitleBar ? Visibility.Collapsed : Visibility.Visible;
        AppNameText.Visibility = iconOnlyTitleBar ? Visibility.Collapsed : Visibility.Visible;
        AppLogo.Width = compactTitleBar ? 22 : 28;
        AppLogo.Height = compactTitleBar ? 15 : 19;
        AppNameText.FontSize = compactTitleBar ? 11 : 12;
        SettingsButton.Width = compactTitleBar ? 24 : 28;
        SettingsButton.Height = compactTitleBar ? 24 : 28;
        SettingsButton.Margin = compactTitleBar ? new Thickness(6, 0, 6, 0) : new Thickness(10, 0, 10, 0);
        AppTitleBar.Margin = new Thickness(iconOnlyTitleBar ? 10 : 14, 0, 160, 0);

        // Width the session statistics actually get: the whole window when stacked, minus the
        // sidebar and the gap between the columns when they sit side by side.
        double statsWidth = narrow ? width : width - 240 - 22;
        SetSessionStatsColumns(statsWidth switch
        {
            < 380 => 2,
            < 620 => 3,
            _ => 5
        });

        ScheduleActivityListHeightUpdate();
    }

    /// <summary>
    /// Reflows the five session statistics across the given number of columns. Five across a narrow
    /// window leaves each one narrower than its own label, which clips rather than wraps.
    /// </summary>
    private void SetSessionStatsColumns(int columns)
    {
        StackPanel[] stats = [CopiedStat, SkippedStat, ProcessedStat, ThroughputStat, ElapsedStat];
        if (SessionStatsGrid.ColumnDefinitions.Count == columns)
        {
            return;
        }

        int rows = (int)Math.Ceiling((double)stats.Length / columns);
        SessionStatsGrid.ColumnDefinitions.Clear();
        for (int column = 0; column < columns; column++)
        {
            SessionStatsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        SessionStatsGrid.RowDefinitions.Clear();
        for (int row = 0; row < rows; row++)
        {
            SessionStatsGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }

        for (int index = 0; index < stats.Length; index++)
        {
            Grid.SetColumn(stats[index], index % columns);
            Grid.SetRow(stats[index], index / columns);
        }

        SessionStatsGrid.RowSpacing = rows > 1 ? 13 : 0;
    }

    /// <summary>
    /// The sizing below measures a laid-out window, so it has to run after the layout pass a resize
    /// triggers rather than inside the event that announces the resize.
    /// </summary>
    private void ScheduleActivityListHeightUpdate() =>
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, UpdateActivityListHeight);

    /// <summary>
    /// Every row of the layout is Auto-sized inside a ScrollViewer, so a window taller than the
    /// content leaves dead space below the erase panel. The activity list is the one element that
    /// can usefully absorb it. Measuring the rest of the layout, rather than hard-coding its
    /// height, keeps this correct as the panels above it grow and shrink.
    /// </summary>
    private void UpdateActivityListHeight() => ApplyActivityListHeight(RootScrollViewer.ViewportHeight);

    private void ApplyActivityListHeight(double viewportHeight)
    {
        if (ActivitySection.Visibility != Visibility.Visible)
        {
            return;
        }

        // DesiredSize, not ActualHeight: a ScrollViewer stretches content shorter than its viewport,
        // so ActualHeight reports the viewport back and the arithmetic below cancels out. DesiredSize
        // is what the content asked for. Subtracting the list leaves a figure that does not move when
        // the list is resized, so this converges in one pass rather than oscillating.
        double everythingElse = MainLayout.DesiredSize.Height - ActivityList.ActualHeight;
        if (viewportHeight <= 0 || everythingElse <= 0)
        {
            return;
        }

        ActivityList.Height = Math.Clamp(
            viewportHeight - everythingElse,
            MinimumActivityHeight,
            MaximumActivityHeight);
    }

    private void SetProgressFill(double startPercent, double widthPercent, bool complete)
    {
        startPercent = Math.Clamp(startPercent, 0, 100);
        widthPercent = Math.Clamp(widthPercent, 0, 100 - startPercent);
        ProgressFillRectangle.Fill = complete ? _progressFillCompleteBrush : _progressFillActiveBrush;
        ProgressBeforeColumn.Width = new GridLength(startPercent, GridUnitType.Star);
        ProgressFillColumn.Width = new GridLength(widthPercent, GridUnitType.Star);
        ProgressAfterColumn.Width = new GridLength(100 - startPercent - widthPercent, GridUnitType.Star);
    }

    private void UpdateSegmentedProgress(double percent, bool complete)
    {
        _scanPulseTimer.Stop();
        SetProgressFill(0, percent, complete);
    }

    private void StartScanPulse()
    {
        if (_scanPulseTimer.IsRunning)
        {
            return;
        }
        _scanPulsePosition = 0;
        _scanPulseDirection = 1;
        _scanPulseTimer.Start();
    }

    private void AdvanceScanPulse()
    {
        double travel = 100 - ScanPulseWidthPercent;
        _scanPulsePosition += _scanPulseDirection * 2.5;
        if (_scanPulsePosition >= travel)
        {
            _scanPulsePosition = travel;
            _scanPulseDirection = -1;
        }
        else if (_scanPulsePosition <= 0)
        {
            _scanPulsePosition = 0;
            _scanPulseDirection = 1;
        }
        SetProgressFill(_scanPulsePosition, ScanPulseWidthPercent, complete: false);
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
        ActivityToggle.IsOn = _settings.ShowActivityLog;
        ActivitySection.Visibility = _settings.ShowActivityLog ? Visibility.Visible : Visibility.Collapsed;
        ScheduleActivityListHeightUpdate();
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
            SetTopStatus("Choose a destination", ErrorStatusColor);

            // The window was already hidden immediately on launch (see the Activated handler
            // above) so a bad saved destination isn't silently invisible in the tray — surface
            // the window so the error is actually seen.
            if (_launchInBackground)
            {
                ShowWindow();
            }
        }
    }

    private async Task ScanCardsAsync(bool force = false)
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
            string? selectedRoot = cards.Count > 0 ? cards[0].RootPath : null;
            bool isNew = _cardPresence.Observe(selectedRoot, activeRoots);
            if (cards.Count == 0)
            {
                _currentCard = null;
                _verifiedSession = null;
                _lastScannedMediaCount = -1;
                _unverifiableFileCount = 0;
                _lastScanSignature = null;
                UpdateDisconnectedState();
                return;
            }

            CardInfo card = cards[0];
            bool cardChanged = _currentCard is null ||
                               !_currentCard.RootPath.Equals(card.RootPath, StringComparison.OrdinalIgnoreCase);
            TransferSession? previousSession = _verifiedSession;
            int previousMediaCount = _lastScannedMediaCount;
            int previousUnverifiableCount = _unverifiableFileCount;

            _currentCard = card;

            // This runs every two seconds for as long as a card stays connected. Walking the whole
            // card and re-reading the session reports each time is minutes of pointless reader and
            // disk traffic on a full card, so skip it while the card looks untouched. Adding or
            // removing anything on a camera card moves the free-space figure, which is read fresh by
            // GetCandidates above.
            string scanSignature = $"{card.RootPath}|{card.VolumeSerial}|{card.FreeBytes}";
            if (!force && !isNew && !cardChanged && scanSignature == _lastScanSignature)
            {
                return;
            }
            _lastScanSignature = scanSignature;
            CardScan scan = await Task.Run(() => MediaClassifier.ScanCard(card.RootPath));
            IReadOnlyList<MediaItem> media = scan.Media;
            _unverifiableFileCount = scan.UnverifiableFiles.Count;
            _lastScannedMediaCount = media.Count;
            CardStatsText.Text = $"{media.Count:N0} assets · {FormatBytes(media.Sum(item => item.Size))}";
            UpdateCardContents(media);
            _verifiedSession = await _stateStore.LoadLatestVerifiedForCardAsync(card);

            // WipeService refuses a card holding content no transfer could have copied. Reflect that
            // here so erase reads as locked, rather than accepting the typed confirmation and only
            // then refusing.
            bool canWipe = _verifiedSession is { Files.Count: > 0 } && _unverifiableFileCount == 0;
            bool verificationChanged = previousSession?.SessionId != _verifiedSession?.SessionId;
            WipeButton.IsEnabled = canWipe;
            if (cardChanged || previousMediaCount != media.Count || verificationChanged ||
                previousUnverifiableCount != _unverifiableFileCount)
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

                // The in-app activity list holds six lines and is gone when the app restarts. This
                // app spends most of its life in the tray, so card arrivals belong in the log too —
                // it is the only record available when diagnosing a transfer that ran unattended.
                await _logger.WriteAsync(
                    $"Detected {card.VolumeLabel} at {card.RootPath}: {media.Count:N0} media file(s), " +
                    $"{_unverifiableFileCount:N0} unverifiable");
                if (_unverifiableFileCount > 0)
                {
                    AddActivity(
                        $"{_unverifiableFileCount:N0} unrecognised file(s) on this card cannot be verified — erase stays locked.");
                }

                // A freshly inserted card is the one moment this app has something to say, so
                // surface the window whenever it is hidden — not only when the process happened to
                // be launched with --background. Closing the window sends it to the tray, and
                // without this an auto-transfer would otherwise run entirely out of sight.
                if (!_appWindow.IsVisible)
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
            await ScanCardsAsync(force: true);
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
        _operationStartedUtc = DateTimeOffset.UtcNow;
        _operationCancellation = new CancellationTokenSource();
        StatusInfoBar.IsOpen = false;
        SetOperationControls(true, allowCancel: true);
        TransferButton.Content = "Scanning media…";
        HeroTitleText.Text = "Copying and verifying your media.";
        HeroSubtitleText.Text = "Each file is written safely, checked with SHA-256, then made visible at the destination.";
        SetTopStatus("Transfer active", ActiveStatusColor);
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
            UpdateVerifiedState(_currentCard, result.Session, justCompleted: true);
            AddActivity(
                $"Verified {result.Session.TotalFiles:N0} files — " +
                $"{result.Session.CopiedCount:N0} copied, {result.Session.SkippedCount:N0} already safe.");
            ShowMessage(
                "Transfer verified",
                $"{result.Session.TotalFiles:N0} files safe in the destination — " +
                $"SHA-256 matched on every remaining camera file · finished {DateTime.Now:HH:mm:ss}",
                InfoBarSeverity.Success);
            ShowNotification(
                "Transfer verified",
                $"{result.Session.TotalFiles:N0} files match their destination copies.");
        }
        catch (OperationCanceledException)
        {
            PhaseText.Text = "CANCELLED";
            AddActivity("Transfer cancelled. Completed files remain safe; temporary files were removed.");
            SetTopStatus("Transfer cancelled", WarningStatusColor);
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
            SetTopStatus("Needs attention", ErrorStatusColor);
        }
        finally
        {
            _scanPulseTimer.Stop();
            if (_lastScannedMediaCount > 0)
            {
                TransferButton.Content = _verifiedSession is null ? "Transfer + verify" : "Transfer again";
            }
            _operationCancellation.Dispose();
            _operationCancellation = null;
            _busy = false;
            SetOperationControls(false, allowCancel: false);

            // Reading the card does not move its free space, so let the next tick re-derive state
            // rather than have the skip-unchanged check hold on to what was true before the transfer.
            _lastScanSignature = null;
        }
    }

    private async Task ConfirmAndWipeAsync()
    {
        if (_busy || _currentCard is null || _verifiedSession is null)
        {
            return;
        }

        // Captured so the erase that actually runs is the card and session shown in this dialog,
        // not whatever _currentCard/_verifiedSession happen to be once the user responds. The scan
        // timer keeps running while this dialog awaits input, and can reassign both fields (e.g. the
        // card is pulled, or swapped for a different already-verified card) before the user answers.
        CardInfo targetCard = _currentCard;
        TransferSession targetSession = _verifiedSession;

        var phrase = new TextBox
        {
            Header = "Type ERASE EVERYTHING to continue",
            PlaceholderText = "ERASE EVERYTHING"
        };
        var acknowledge = new CheckBox
        {
            Content = $"I understand this removes all files and folders from {targetCard.RootPath}."
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

        // _busy was only false when this dialog opened. The scan timer keeps ticking while it waits
        // for input, and with auto-transfer on an inserted card starts a transfer from that tick —
        // so an erase confirmed now would delete the very files a transfer is still reading.
        if (_busy)
        {
            ShowError(
                "Operation in progress",
                "A transfer started while the confirmation was open. Wait for it to finish, then erase the card.");
            AddActivity("Erase cancelled: a transfer started during confirmation.");
            return;
        }

        bool stillMatches = _currentCard is not null &&
            _currentCard.RootPath.Equals(targetCard.RootPath, StringComparison.OrdinalIgnoreCase) &&
            _currentCard.VolumeSerial == targetCard.VolumeSerial &&
            _verifiedSession?.SessionId == targetSession.SessionId;
        if (!stillMatches)
        {
            ShowError(
                "Card changed",
                "The connected card changed while the confirmation was open. Reconnect the card and try erasing again.");
            AddActivity("Erase cancelled: the connected card changed during confirmation.");
            return;
        }

        _busy = true;
        _operationStartedUtc = DateTimeOffset.UtcNow;
        StatusInfoBar.IsOpen = false;
        SetOperationControls(true, allowCancel: false);
        WipeButton.IsEnabled = false;
        HeroTitleText.Text = "Re-verifying before erase.";
        HeroSubtitleText.Text = "Deletion starts only after every remaining media file matches its destination copy.";
        SetTopStatus("Erase active", ActiveStatusColor);
        AddActivity("Erase approved. Re-verifying card media before deletion.");

        try
        {
            var progress = new Progress<OperationProgress>(UpdateProgress);
            WipeResult result = await _wipeService.WipeEverythingAsync(
                targetCard,
                targetSession,
                progress,
                CancellationToken.None);
            _verifiedSession = null;
            _lastScannedMediaCount = 0;
            _lastSessionFilePath = null;
            ReportButton.IsEnabled = false;
            SessionTransferAgainButton.IsEnabled = false;
            UpdateEraseBadge(unlocked: false);
            HeroTitleText.Text = "Card contents erased.";
            HeroSubtitleText.Text =
                "The post-erase scan found no remaining media or user content. The card is ready for the camera.";
            TransferButton.Content = "No media found";
            WipeDescriptionText.Text = "Erase complete. Connect another card or use this card in your camera.";
            SetTopStatus("Card empty", VerifiedStatusColor);
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
            SetTopStatus("Erase needs attention", ErrorStatusColor);
            WipeButton.IsEnabled = _verifiedSession is not null;
        }
        finally
        {
            _busy = false;
            SetOperationControls(false, allowCancel: false);
            _lastScanSignature = null;
        }
    }

    private void UpdateProgress(OperationProgress progress)
    {
        bool complete = progress.Phase == OperationPhase.Complete;
        if (progress.Phase == OperationPhase.Scanning)
        {
            StartScanPulse();
        }
        else
        {
            UpdateSegmentedProgress(progress.Percent, complete);
        }
        if (progress.Phase == OperationPhase.Scanning)
        {
            TransferButton.Content = "Scanning media…";
        }
        else if (progress.Phase is OperationPhase.CheckingDuplicate or OperationPhase.Copying or OperationPhase.Verifying)
        {
            TransferButton.Content = "Transfer in progress";
        }
        PhaseText.Text = progress.Phase switch
        {
            OperationPhase.CheckingDuplicate => "CHECKING DUPLICATE",
            OperationPhase.ReVerifying => "RE-VERIFYING",
            OperationPhase.Erasing => "ERASING CONTENTS",
            _ => progress.Phase.ToString().ToUpperInvariant()
        };
        if (!complete)
        {
            CurrentFileText.Text = FormatCurrentActivity(progress);
        }
        PercentText.Text = $"{progress.Percent:0}%";
        CopiedText.Text = $"{progress.CopiedFiles:N0} files";
        SkippedText.Text = $"{progress.SkippedFiles:N0} files";
        ProcessedText.Text = FormatBytes(progress.ProcessedBytes);

        TimeSpan elapsed = _operationStartedUtc is { } startedAt ? DateTimeOffset.UtcNow - startedAt : TimeSpan.Zero;
        ElapsedText.Text = FormatElapsed(elapsed);
        ThroughputText.Text = elapsed.TotalSeconds >= 1
            ? FormatThroughput(progress.ProcessedBytes, elapsed)
            : "—";
    }

    private static string FormatCurrentActivity(OperationProgress progress)
    {
        const string Verb = "CURRENT";
        if (string.IsNullOrEmpty(progress.CurrentSourcePath))
        {
            return $"{Verb} · {progress.CurrentItem}";
        }
        return string.IsNullOrEmpty(progress.CurrentDestinationFolder)
            ? $"{Verb} · {progress.CurrentSourcePath}"
            : $"{Verb} · {progress.CurrentSourcePath} → {progress.CurrentDestinationFolder}";
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        int totalSeconds = Math.Max(0, (int)elapsed.TotalSeconds);
        return $"{totalSeconds / 60}:{totalSeconds % 60:00}";
    }

    private static string FormatThroughput(long processedBytes, TimeSpan elapsed)
    {
        double megabytesPerSecond = processedBytes / 1024.0 / 1024.0 / elapsed.TotalSeconds;
        return $"{megabytesPerSecond:0} MB/s avg";
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
        _settings.ShowActivityLog = ActivityToggle.IsOn;
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
        WipeDescriptionText.Text = LockedEraseDescription();
        UpdateEraseBadge(unlocked: false);
        SetTopStatus("Media detected", ActiveStatusColor);
        ApplySessionFooter(null, "Ready to transfer and verify");
    }

    private void UpdateVerifiedState(CardInfo card, TransferSession session, bool justCompleted = false)
    {
        UpdateCardSummary(card);
        HeroTitleText.Text = justCompleted ? "Transfer verified." : "Transfer already verified.";
        HeroSubtitleText.Text = justCompleted
            ? $"{session.TotalFiles:N0} media files match their destination copies. Erase is now available."
            : $"{session.TotalFiles:N0} media files still match their destination copies. You can transfer again or erase the card.";
        TransferButton.Content = "Transfer again";
        TransferButton.IsEnabled = !_busy && _destinationAvailable;
        WipeButton.IsEnabled = true;
        WipeDescriptionText.Text = "Unlocked — every remaining media file has a verified destination copy.";
        UpdateEraseBadge(unlocked: true);
        SetTopStatus($"{card.VolumeLabel} CONNECTED", VerifiedStatusColor);
        ApplySessionFooter(session);
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
            : _unverifiableFileCount > 0
                ? LockedEraseDescription()
                : "Locked until a transfer completes and every media file is verified.";
        UpdateEraseBadge(unlocked: canWipe);
        SetTopStatus(
            canWipe ? $"{card.VolumeLabel} CONNECTED" : "Card empty",
            canWipe ? VerifiedStatusColor : NeutralStatusColor);
        ApplySessionFooter(canWipe ? _verifiedSession : null, "No supported media on this card");
    }

    private string LockedEraseDescription() => _unverifiableFileCount switch
    {
        0 => "Locked until every remaining media file has a verified destination copy.",
        1 => "Locked — one file on this card is not recognised camera media, so no transfer can verify it. Copy it off the card yourself.",
        _ => $"Locked — {_unverifiableFileCount:N0} files on this card are not recognised camera media, so no transfer can verify them. Copy them off the card yourself."
    };

    private void UpdateCardSummary(CardInfo card)
    {
        CardLabelText.Text = card.VolumeLabel;
        CardDetailText.Text = $"{card.RootPath} · {card.DriveType} media";
    }

    private void UpdateDisconnectedState()
    {
        CardLabelText.Text = "No card connected";
        CardDetailText.Text = "Insert a removable camera card to begin.";
        CardStatsText.Text = "—";
        UpdateCardContents([]);
        HeroTitleText.Text = "Ready for your next card.";
        HeroSubtitleText.Text =
            "JPEGs, RAWs, and video are sorted automatically. Every media file is SHA-256 verified before erase is available.";
        TransferButton.Content = "Scan for media";
        TransferButton.IsEnabled = !_busy && _destinationAvailable;
        WipeButton.IsEnabled = false;
        WipeDescriptionText.Text = "Locked until every remaining media file has a verified destination copy.";
        UpdateEraseBadge(unlocked: false);
        SetTopStatus("Waiting for media", NeutralStatusColor);
        ApplySessionFooter(null);
    }

    private void UpdateCardContents(IReadOnlyList<MediaItem> media)
    {
        int jpeg = 0, raw = 0, other = 0, video = 0;
        foreach (MediaItem item in media)
        {
            switch (item.Kind)
            {
                case MediaKind.Jpeg: jpeg++; break;
                case MediaKind.Raw: raw++; break;
                case MediaKind.OtherPhoto: other++; break;
                case MediaKind.Video: video++; break;
            }
        }
        int total = jpeg + raw + other + video;

        JpegCountText.Text = total == 0 ? "—" : jpeg.ToString("N0");
        RawCountText.Text = total == 0 ? "—" : raw.ToString("N0");
        OtherCountText.Text = total == 0 ? "—" : other.ToString("N0");
        VideoCountText.Text = total == 0 ? "—" : video.ToString("N0");

        JpegSegmentColumn.Width = new GridLength(total == 0 ? 1 : jpeg, GridUnitType.Star);
        RawSegmentColumn.Width = new GridLength(total == 0 ? 1 : raw, GridUnitType.Star);
        OtherSegmentColumn.Width = new GridLength(total == 0 ? 1 : other, GridUnitType.Star);
        VideoSegmentColumn.Width = new GridLength(total == 0 ? 1 : video, GridUnitType.Star);
        CardContentsBar.Opacity = total == 0 ? 0.35 : 1.0;
    }

    private void UpdateEraseBadge(bool unlocked)
    {
        EraseLockedBadge.Visibility = unlocked ? Visibility.Collapsed : Visibility.Visible;
        EraseUnlockedBadge.Visibility = unlocked ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ApplySessionFooter(TransferSession? session, string idleMessage = "Waiting for camera media")
    {
        bool hasSession = session is not null;
        ReportButton.IsEnabled = !_busy && hasSession;
        SessionTransferAgainButton.IsEnabled = !_busy && _destinationAvailable && hasSession;
        _lastSessionFilePath = hasSession ? _stateStore.SessionFilePath(session!) : null;

        TransferRecord? lastRecord = session?.Files.LastOrDefault();
        if (session is null || lastRecord is null)
        {
            CurrentFileText.Text = idleMessage;
            return;
        }

        string destinationFolder = PathUtilities.RelativeDestinationFolder(session.DestinationRoot, lastRecord.DestinationPath);
        CurrentFileText.Text = $"LAST · {lastRecord.SourcePath} → {destinationFolder}";
    }

    private void OpenSessionReport()
    {
        if (_lastSessionFilePath is null || !File.Exists(_lastSessionFilePath))
        {
            ShowError("Report unavailable", "The saved transfer report could not be found.");
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{_lastSessionFilePath}\"") { UseShellExecute = true });
        }
        catch (Exception exception) when (exception is Win32Exception or IOException)
        {
            ShowError("Report unavailable", exception.Message);
        }
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
        ActivityToggle.IsEnabled = !active;
        StartupToggle.IsEnabled = !active;
        ChangeDestinationButton.IsEnabled = !active;
        OpenFolderButton.IsEnabled = !active && _destinationAvailable;
        ThemeComboBox.IsEnabled = !active;
        SettingsButton.IsEnabled = !active;
        ReportButton.IsEnabled = !active && _lastSessionFilePath is not null;
        SessionTransferAgainButton.IsEnabled = !active && _destinationAvailable && _verifiedSession is not null;
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
            AddActivity($"Destination changed to {_destinationRoot}");
            ShowMessage(
                "Destination updated",
                "New transfers will use the selected folder.",
                InfoBarSeverity.Success);
            await ScanCardsAsync(force: true);
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
        UpdateTitleBarColors();
    }

    private void UpdateTitleBarColors()
    {
        bool isLight = Root.ActualTheme == ElementTheme.Light;
        Color foreground = isLight
            ? Color.FromArgb(255, 31, 31, 31)
            : Color.FromArgb(255, 255, 255, 255);
        Color inactiveForeground = isLight
            ? Color.FromArgb(153, 31, 31, 31)
            : Color.FromArgb(166, 255, 255, 255);

        _appWindow.TitleBar.ButtonForegroundColor = foreground;
        _appWindow.TitleBar.ButtonHoverForegroundColor = foreground;
        _appWindow.TitleBar.ButtonPressedForegroundColor = foreground;
        _appWindow.TitleBar.ButtonInactiveForegroundColor = inactiveForeground;
        _appWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonHoverBackgroundColor = isLight
            ? Color.FromArgb(20, 0, 0, 0)
            : Color.FromArgb(28, 255, 255, 255);
        _appWindow.TitleBar.ButtonPressedBackgroundColor = isLight
            ? Color.FromArgb(36, 0, 0, 0)
            : Color.FromArgb(48, 255, 255, 255);
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
            SetTopStatus("Choose a destination", ErrorStatusColor);
        }
    }

    private void ShowWindow()
    {
        if (_placementPending)
        {
            _placementPending = false;
            SizeAndCenterWindow(_windowHandle);
        }
        _appWindow.Show();
        Activate();
        NativeMethods.ActivateWindow(_windowHandle);
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
        ShowNotification("Media Shuttle is still watching", "Click the tray icon to reopen the app.");
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
