// EpicSteamLauncher - lets Steam launch and track an Epic Games Store title.
//
// Steam starts this exe as a non-Steam shortcut. It:
//   1. opens the game's Epic launch URI (Epic -> publisher launcher -> game, the normal DRM/anti-cheat chain)
//   2. waits for the real game process to appear (gives up after --timeout seconds, so it can never hang)
//   3. stays alive while the game runs, so Steam shows "Playing" and keeps the shortcut's session
//   4. exits when the game exits (optionally closing leftover launcher windows), so Steam / Big Picture returns
//
// No windows, no overlay, no input hooks, no device hiding.
//
// Usage (Steam launch options):
//   --uri "<com.epicgames.launcher://...>" --game GTA5_Enhanced [--timeout 300] [--grace 8]
//   [--kill-path "Rockstar Games\Launcher"] [--dry-run]
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class EpicSteamLauncher
{
    static string logPath;

    static void Log(string msg)
    {
        try { File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine); }
        catch { }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder buf, ref int size);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    static string ProcPath(Process p)
    {
        IntPtr h = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, p.Id);
        if (h == IntPtr.Zero) return "";
        try
        {
            var sb = new StringBuilder(1024); int n = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : "";
        }
        finally { CloseHandle(h); }
    }

    static Process[] Find(string name)
    {
        try { return Process.GetProcessesByName(name); } catch { return new Process[0]; }
    }

    static int Main(string[] args)
    {
        // log next to the exe (not under AppData, which some apps virtualize per-package)
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        logPath = Path.Combine(dir, "log.txt");
        try { if (File.Exists(logPath) && new FileInfo(logPath).Length > 512 * 1024) File.Delete(logPath); } catch { }

        string uri = null, game = null, epicExe = null; var killPaths = new List<string>();
        int timeout = 300, grace = 8; bool dry = false, chain = false;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            string next = i + 1 < args.Length ? args[i + 1] : null;
            if (a == "--uri" && next != null) { uri = next; i++; }
            else if (a == "--game" && next != null) { game = next; i++; }
            else if (a == "--timeout" && next != null) { int.TryParse(next, out timeout); i++; }
            else if (a == "--grace" && next != null) { int.TryParse(next, out grace); i++; }
            else if (a == "--kill-path" && next != null) { killPaths.Add(next); i++; }
            else if (a == "--epic-exe" && next != null) { epicExe = next; i++; }
            else if (a == "--chain") chain = true;
            else if (a == "--dry-run") dry = true;
        }
        if (game != null && game.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) game = game.Substring(0, game.Length - 4);

        Log("---- start: game=" + game + " timeout=" + timeout + "s chain=" + chain + " dry=" + dry);
        Log("steam overlay in this launcher: " + (HasOverlay(Process.GetCurrentProcess()) ? "yes" : "no"));
        if (string.IsNullOrEmpty(uri) || string.IsNullOrEmpty(game)) { Log("ERROR: --uri and --game are required"); return 2; }
        if (chain && epicExe == null) epicExe = EpicExeFromRegistry();
        if (chain && (epicExe == null || !File.Exists(epicExe))) { Log("chain: Epic exe not found (" + epicExe + "); falling back to normal launch"); chain = false; }

        // 1. launch through Epic (skip if the game is already running)
        Process epic = null;
        if (Find(game).Length == 0)
        {
            if (chain)
            {
                // Chain mode: Steam -> this launcher -> Epic -> PlayGTAV -> Rockstar Launcher -> game.
                // Epic and the publisher launcher must be started fresh by us, so the game ends up
                // inside Steam's process tree and gets Steam's own overlay and Steam Input.
                CloseMatching(n => n.EndsWith("\\EpicGamesLauncher.exe", StringComparison.OrdinalIgnoreCase)
                                || n.EndsWith("\\EpicWebHelper.exe", StringComparison.OrdinalIgnoreCase), "before launch", dry);
                CloseMatching(n => killPaths.Exists(k => n.IndexOf(k, StringComparison.OrdinalIgnoreCase) >= 0), "before launch", dry);
                if (dry) Log("dry-run: would start " + epicExe + " \"" + uri + "\"");
                else
                {
                    try
                    {
                        var psi = new ProcessStartInfo(epicExe, "\"" + uri + "\"") { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(epicExe) };
                        // Steam passes "this is Steam game X" markers down the chain; the Rockstar Launcher then
                        // thinks it's the Steam edition and fails. Remove them (keep SteamOverlayGameId for the overlay).
                        var steamVars = new List<string>();
                        foreach (string k in psi.EnvironmentVariables.Keys) if (k.StartsWith("Steam", StringComparison.OrdinalIgnoreCase)) steamVars.Add(k);
                        Log("steam env vars seen: " + string.Join(", ", steamVars.ToArray()));
                        foreach (var k in steamVars)
                            if (!k.Equals("SteamOverlayGameId", StringComparison.OrdinalIgnoreCase)) psi.EnvironmentVariables.Remove(k);
                        epic = Process.Start(psi);
                        Log("chain: started Epic as our child, pid " + epic.Id);
                    }
                    catch (Exception e) { Log("ERROR starting Epic: " + e.Message); return 3; }
                }
            }
            else if (dry) Log("dry-run: would open " + uri);
            else
            {
                try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); Log("opened Epic URI"); }
                catch (Exception e) { Log("ERROR opening URI: " + e.Message); return 3; }
            }
        }
        else Log("game already running; attaching");

        // 2. wait for the game to appear
        var sw = Stopwatch.StartNew();
        while (Find(game).Length == 0)
        {
            if (sw.Elapsed.TotalSeconds > timeout) { Log("game did not start within " + timeout + "s; exiting"); return 1; }
            Thread.Sleep(1000);
        }
        Log("game running after " + (int)sw.Elapsed.TotalSeconds + "s");
        // report which processes in the chain carry Steam's overlay (the game itself may refuse inspection under anti-cheat)
        Thread.Sleep(15000);
        foreach (var name in new[] { "EpicGamesLauncher", "PlayGTAV", "Launcher", game })
            foreach (var p in Find(name))
                Log("overlay check " + name + " pid " + p.Id + ": " + OverlayState(p));

        // 3. stay alive while it runs (grace period covers quick restarts, e.g. after updates)
        while (true)
        {
            while (Find(game).Length > 0) Thread.Sleep(2000);
            Log("game exited; waiting " + grace + "s grace");
            Thread.Sleep(grace * 1000);
            if (Find(game).Length == 0) break;
            Log("game came back; continuing");
        }

        // 4. close leftover launcher windows (only processes whose path matches --kill-path)
        CloseMatching(n => killPaths.Exists(k => n.IndexOf(k, StringComparison.OrdinalIgnoreCase) >= 0), "after game", dry);
        // in chain mode we started Epic, so close it too; otherwise Steam keeps showing the game as running
        if (chain)
            CloseMatching(n => n.EndsWith("\\EpicGamesLauncher.exe", StringComparison.OrdinalIgnoreCase)
                            || n.EndsWith("\\EpicWebHelper.exe", StringComparison.OrdinalIgnoreCase), "after game", dry);
        Log("done");
        return 0;
    }

    static void CloseMatching(Func<string, bool> match, string when, bool dry)
    {
        foreach (var p in Process.GetProcesses())
        {
            string path = ProcPath(p);
            if (path.Length == 0 || !match(path)) continue;
            if (dry) { Log("dry-run: would close (" + when + ") " + path); continue; }
            try
            {
                if (!(p.CloseMainWindow() && p.WaitForExit(5000))) { p.Kill(); p.WaitForExit(5000); }
                Log("closed (" + when + ") " + path);
            }
            catch (Exception e) { Log("could not close " + path + ": " + e.Message); }
        }
    }

    static string EpicExeFromRegistry()
    {
        try
        {
            using (var k = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey(@"com.epicgames.launcher\shell\open\command"))
            {
                string cmd = k == null ? null : k.GetValue("") as string;
                if (string.IsNullOrEmpty(cmd)) return null;
                if (cmd.StartsWith("\"")) return cmd.Substring(1, cmd.IndexOf('"', 1) - 1);
                return cmd.Split(' ')[0];
            }
        }
        catch { return null; }
    }

    static bool HasOverlay(Process p)
    {
        try { foreach (ProcessModule m in p.Modules) if (m.ModuleName.StartsWith("gameoverlayrenderer", StringComparison.OrdinalIgnoreCase)) return true; }
        catch { }
        return false;
    }

    static string OverlayState(Process p)
    {
        try
        {
            foreach (ProcessModule m in p.Modules)
                if (m.ModuleName.StartsWith("gameoverlayrenderer", StringComparison.OrdinalIgnoreCase)) return "Steam overlay loaded";
            return "no Steam overlay";
        }
        catch (Exception e) { return "can't inspect (" + e.Message + ")"; }
    }
}
