using System.Runtime.InteropServices;

namespace MediaShuttle;

internal sealed class TrayIconService : IDisposable
{
    private const uint NimAdd = 0x00000000;
    private const uint NimModify = 0x00000001;
    private const uint NimDelete = 0x00000002;
    private const uint NimSetVersion = 0x00000004;
    private const uint NotifyIconVersion4 = 4;
    private const uint NifMessage = 0x00000001;
    private const uint NifIcon = 0x00000002;
    private const uint NifTip = 0x00000004;
    private const uint NifInfo = 0x00000010;
    private const uint NiifInfo = 0x00000001;
    private const uint WmApp = 0x8000;
    private const uint CallbackMessage = WmApp + 42;
    private const int WmLButtonDoubleClick = 0x0203;
    private const int WmRButtonUp = 0x0205;
    private const int WmContextMenu = 0x007B;

    // NIM_SETVERSION with version 4 (below) changes which events the shell reports: a plain click or
    // keyboard activation arrives as NIN_SELECT/NIN_KEYSELECT rather than the WM_LBUTTON* messages a
    // version-0 icon would send. Without these the tray icon ignores single clicks, which is the
    // only way back to a window the user has closed into the tray.
    private const int NinSelect = 0x0400;
    private const int NinKeySelect = 0x0401;
    private const uint WmNull = 0x0000;
    private const uint ImageIcon = 1;
    private const uint LrLoadFromFile = 0x0010;
    private const uint MfString = 0x0000;
    private const uint MfSeparator = 0x0800;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCommand = 0x0100;
    private readonly IntPtr _windowHandle;
    private readonly Action _open;
    private readonly Action _openFolder;
    private readonly Action _exit;
    private readonly Action _chooseSource;
    private readonly Action _transfer;
    private readonly Func<bool> _canChooseSource;
    private readonly Func<bool> _canTransfer;
    private readonly SubclassProcedure _subclassProcedure;
    private readonly UIntPtr _subclassId = new(0x4D534855);
    private NotifyIconData _data;
    private IntPtr _iconHandle;
    private bool _disposed;

    public TrayIconService(
        IntPtr windowHandle,
        string iconPath,
        Action open,
        Action openFolder,
        Action exit,
        Action chooseSource,
        Action transfer,
        Func<bool> canChooseSource,
        Func<bool> canTransfer)
    {
        _windowHandle = windowHandle;
        _open = open;
        _openFolder = openFolder;
        _exit = exit;
        _chooseSource = chooseSource;
        _transfer = transfer;
        _canChooseSource = canChooseSource;
        _canTransfer = canTransfer;
        _subclassProcedure = WindowSubclass;
        _iconHandle = LoadImage(IntPtr.Zero, iconPath, ImageIcon, 32, 32, LrLoadFromFile);
        if (_iconHandle == IntPtr.Zero)
        {
            _iconHandle = LoadIcon(IntPtr.Zero, new IntPtr(32512));
        }

        _data = CreateData(NifMessage | NifIcon | NifTip);
        _data.WindowHandle = _windowHandle;
        _data.IconId = 1;
        _data.CallbackMessage = CallbackMessage;
        _data.IconHandle = _iconHandle;
        _data.Tooltip = "Media Shuttle";
        SetWindowSubclass(_windowHandle, _subclassProcedure, _subclassId, UIntPtr.Zero);
        ShellNotifyIcon(NimAdd, ref _data);
        _data.VersionOrTimeout = NotifyIconVersion4;
        ShellNotifyIcon(NimSetVersion, ref _data);
    }

    public void ShowNotification(string title, string message)
    {
        if (_disposed)
        {
            return;
        }
        NotifyIconData notification = CreateData(NifInfo);
        notification.WindowHandle = _windowHandle;
        notification.IconId = 1;
        notification.InfoTitle = Truncate(title, 63);
        notification.Info = Truncate(message, 255);
        notification.InfoFlags = NiifInfo;
        ShellNotifyIcon(NimModify, ref notification);
    }

    private IntPtr WindowSubclass(
        IntPtr window,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        UIntPtr referenceData)
    {
        if (message == CallbackMessage)
        {
            int notificationMessage = unchecked((int)(lParam.ToInt64() & 0xFFFF));
            if (notificationMessage is NinSelect or NinKeySelect or WmLButtonDoubleClick)
            {
                _open();
            }
            else if (notificationMessage is WmRButtonUp or WmContextMenu)
            {
                // Version 4 reports where the icon was invoked in wParam, which is the correct anchor
                // for a keyboard-invoked menu — the pointer can be anywhere on screen by then.
                ShowContextMenu(
                    unchecked((short)(wParam.ToUInt64() & 0xFFFF)),
                    unchecked((short)((wParam.ToUInt64() >> 16) & 0xFFFF)));
            }
            return IntPtr.Zero;
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }

    private void ShowContextMenu(int anchorX, int anchorY)
    {
        if (anchorX == 0 && anchorY == 0)
        {
            GetCursorPos(out Point point);
            anchorX = point.X;
            anchorY = point.Y;
        }

        IntPtr menu = CreatePopupMenu();
        try
        {
            AppendMenu(menu, MfString, 1, "Open Media Shuttle");
            AppendMenu(menu, _canChooseSource() ? MfString : 1u, 4, "Choose source…");
            AppendMenu(menu, _canTransfer() ? MfString : 1u, 5, "Transfer and verify");
            AppendMenu(menu, MfString, 2, "Open destination folder");
            AppendMenu(menu, MfSeparator, 0, null);
            AppendMenu(menu, MfString, 3, "Exit");
            SetForegroundWindow(_windowHandle);
            uint command = TrackPopupMenu(
                menu,
                TpmRightButton | TpmReturnCommand,
                anchorX,
                anchorY,
                0,
                _windowHandle,
                IntPtr.Zero);

            // TrackPopupMenu leaves the owner window believing the menu is still up, so the next
            // click outside it is swallowed instead of dismissing the menu. The documented fix is to
            // post any message to the owner once tracking ends.
            PostMessage(_windowHandle, WmNull, UIntPtr.Zero, IntPtr.Zero);
            switch (command)
            {
                case 1:
                    _open();
                    break;
                case 2:
                    _openFolder();
                    break;
                case 3:
                    _exit();
                    break;
                case 4:
                    _chooseSource();
                    break;
                case 5:
                    _transfer();
                    break;
            }
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        ShellNotifyIcon(NimDelete, ref _data);
        RemoveWindowSubclass(_windowHandle, _subclassProcedure, _subclassId);
        if (_iconHandle != IntPtr.Zero)
        {
            DestroyIcon(_iconHandle);
            _iconHandle = IntPtr.Zero;
        }
    }

    private static NotifyIconData CreateData(uint flags) => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Flags = flags,
        Tooltip = string.Empty,
        Info = string.Empty,
        InfoTitle = string.Empty
    };

    private static string Truncate(string value, int maximum) =>
        value.Length <= maximum ? value : value[..maximum];

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr WindowHandle;
        public uint IconId;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr IconHandle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tooltip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;
        public uint VersionOrTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;
        public uint InfoFlags;
        public Guid GuidItem;
        public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    private delegate IntPtr SubclassProcedure(
        IntPtr window,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        UIntPtr referenceData);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint load);

    [DllImport("user32.dll")]
    private static extern IntPtr LoadIcon(IntPtr instance, IntPtr iconName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(IntPtr window, SubclassProcedure procedure, UIntPtr id, UIntPtr data);

    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProcedure procedure, UIntPtr id);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(IntPtr menu, uint flags, uint newItem, string? text);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr window, IntPtr rectangle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
}
