using System.ComponentModel;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Kadr;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var singleInstance = new Mutex(true, @"Local\Kadr.Screenshot.Editor", out bool first);
        if (!first) return;
        WindowsIntegration.RepairInstalledListing();
        using var app = new TrayApp();
        Application.Run(app);
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private readonly Icon icon;
    private readonly NotifyIcon tray;
    private readonly ContextMenuStrip menu;
    private readonly HotKeyWindow hotKey;
    private readonly System.Windows.Forms.Timer captureTimer = new() { Interval = 100 };
    private EditorWindow? editor;
    private WelcomeWindow? welcome;
    private CopyToast? toast;

    public TrayApp()
    {
        using Stream asset = Assembly.GetExecutingAssembly().GetManifestResourceStream("Kadr.ico")!;
        using var source = new Icon(asset);
        icon = (Icon)source.Clone();
        menu = new ContextMenuStrip();
        menu.Items.Add("Открыть Shooter MF", null, (_, _) => OpenWelcome());
        menu.Items.Add("Сделать скриншот", null, (_, _) => QueueCapture());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Завершить Shooter MF", null, (_, _) => ExitThread());
        tray = new NotifyIcon { Icon = icon, Text = $"Shooter MF · {HotKeyWindow.Shortcut}", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) OpenWelcome(); };
        captureTimer.Tick += (_, _) => Capture();
        hotKey = new HotKeyWindow(QueueCapture);
        if (!hotKey.Registered)
        {
            tray.Text = $"Shooter MF · {HotKeyWindow.Shortcut} занято";
            tray.ShowBalloonTip(3500, "Shooter MF", $"{HotKeyWindow.Shortcut} занято. Сделайте снимок через меню значка.", ToolTipIcon.Info);
        }
    }

    private void OpenWelcome()
    {
        if (editor?.IsSaving == true) return;
        if (welcome is null)
        {
            welcome = new WelcomeWindow(icon, QueueCapture, hotKey.Registered);
            welcome.FormClosed += (_, _) => welcome = null;
        }
        welcome.RefreshStartup();
        if (!welcome.Visible) welcome.Show();
        welcome.Activate();
    }

    private void QueueCapture()
    {
        if (editor?.IsSaving == true) return;
        welcome?.Hide();
        editor?.Close();
        toast?.Close();
        captureTimer.Stop();
        captureTimer.Start();
    }

    private void Capture()
    {
        captureTimer.Stop();
        Bitmap? image = null;
        try
        {
            Rectangle desktop = SystemInformation.VirtualScreen;
            image = new Bitmap(desktop.Width, desktop.Height);
            using (Graphics graphics = Graphics.FromImage(image))
                graphics.CopyFromScreen(desktop.Location, Point.Empty, desktop.Size);
            editor = new EditorWindow(image, desktop, ShowToast);
            image = null;
            editor.FormClosed += (_, _) => editor = null;
            editor.Show();
            editor.Activate();
        }
        catch (Exception error) when (error is Win32Exception or ExternalException or ArgumentException)
        {
            image?.Dispose();
            MessageBox.Show($"Не удалось снять экран.\n\n{error.Message}", "Shooter MF", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private void ShowToast(Screen screen)
    {
        toast?.Close();
        toast = new CopyToast(screen);
        toast.FormClosed += (_, _) => toast = null;
        toast.Show();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            captureTimer.Dispose();
            editor?.Close();
            toast?.Close();
            welcome?.Dispose();
            hotKey.Dispose();
            tray.Dispose();
            menu.Dispose();
            icon.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal sealed class HotKeyWindow : NativeWindow, IDisposable
{
    internal const string Shortcut = "Alt+Shift+S";
    private const uint ModAlt = 0x0001;
    private const uint ModShift = 0x0004;
    private const uint ModNoRepeat = 0x4000;

    private readonly Action capture;
    public bool Registered { get; }

    public HotKeyWindow(Action capture)
    {
        this.capture = capture;
        CreateHandle(new CreateParams { Caption = "KadrHotKey", Parent = new IntPtr(-3) });
        Registered = Native.RegisterHotKey(Handle, 1, ModAlt | ModShift | ModNoRepeat, (uint)Keys.S);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x0312 && message.WParam == new IntPtr(1)) capture();
        else base.WndProc(ref message);
    }

    public void Dispose()
    {
        if (Registered) Native.UnregisterHotKey(Handle, 1);
        DestroyHandle();
    }
}

internal static partial class Native
{
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RegisterHotKey(nint window, int id, uint modifiers, uint key);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterHotKey(nint window, int id);

    [LibraryImport("shell32.dll")]
    private static partial int SHGetKnownFolderPath(in Guid folder, uint flags, nint token, out nint path);

    internal static string Downloads()
    {
        Guid downloads = new("374DE290-123F-4565-9164-39C4925E467B");
        int result = SHGetKnownFolderPath(in downloads, 0, 0, out nint path);
        try
        {
            return result == 0 ? Marshal.PtrToStringUni(path)! : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
        finally { Marshal.FreeCoTaskMem(path); }
    }
}
