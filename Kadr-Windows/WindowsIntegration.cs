using Microsoft.Win32;
using System.Security;

namespace Kadr;

internal static class WindowsIntegration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Kadr";
    private const string DisplayName = "Shooter MF";
    private static string StartupCommand => $"\"{Application.ExecutablePath}\"";

    internal static bool StartsAtLogin()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey);
        return string.Equals(key?.GetValue("Kadr") as string, StartupCommand, StringComparison.OrdinalIgnoreCase);
    }

    internal static void SetStartsAtLogin(bool enabled)
    {
        using RegistryKey? key = enabled ? Registry.CurrentUser.CreateSubKey(RunKey)
            : Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (enabled)
        {
            if (key is null) throw new IOException("Недоступны настройки автозапуска Windows.");
            key.SetValue("Kadr", StartupCommand);
        }
        else if (string.Equals(key?.GetValue("Kadr") as string, StartupCommand, StringComparison.OrdinalIgnoreCase))
        {
            key!.DeleteValue("Kadr", throwOnMissingValue: false);
        }
    }

    internal static bool IsRegistryError(Exception error) =>
        error is IOException or UnauthorizedAccessException or SecurityException;

    internal static void RepairInstalledListing()
    {
        string directory = Path.GetDirectoryName(Application.ExecutablePath)!;
        string uninstaller = Path.Combine(directory, "Uninstall.exe");
        if (!File.Exists(uninstaller)) return;

        try
        {
            string standardDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", DisplayName);
            using RegistryKey? existing = Registry.CurrentUser.OpenSubKey(UninstallKey);
            if (!string.Equals(directory, standardDirectory, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(existing?.GetValue("InstallLocation") as string, directory, StringComparison.OrdinalIgnoreCase))
                return;

            string command = $"\"{uninstaller}\"";
            string version = typeof(WindowsIntegration).Assembly.GetName().Version!.ToString(3);
            if (existing is not null && existing.GetValue("DisplayName") as string == DisplayName &&
                existing.GetValue("UninstallString") as string == command &&
                existing.GetValue("DisplayVersion") as string == version &&
                existing.GetValue("SystemComponent") is int visibility && visibility == 0)
                return;

            using RegistryKey? key = Registry.CurrentUser.CreateSubKey(UninstallKey);
            if (key is null) return;
            key.SetValue("DisplayVersion", version);
            key.SetValue("Publisher", DisplayName);
            key.SetValue("DisplayIcon", StartupCommand);
            key.SetValue("InstallLocation", directory);
            key.SetValue("UninstallString", command);
            key.SetValue("QuietUninstallString", command + " /S");
            key.SetValue("SystemComponent", 0);
            key.SetValue("NoModify", 1);
            key.SetValue("NoRepair", 1);
            key.SetValue("DisplayName", DisplayName);
        }
        catch (Exception error) when (IsRegistryError(error)) { }
    }
}
