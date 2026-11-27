// EpicToSteam.exe - opens the Epic to Steam app (ShortcutMaker.ps1 next to this exe) without a console window.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class EpicToSteam
{
    [STAThread]
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "ShortcutMaker.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("ShortcutMaker.ps1 was not found next to EpicToSteam.exe.\nKeep all the files from the download together in one folder.", "Epic to Steam", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };
        Process.Start(psi);
        return 0;
    }
}
