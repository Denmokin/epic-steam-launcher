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
//   [--kill-path "Rockstar Games\Launcher"] [--chain] [--hide-launchers [--hide-for 90]] [--dry-run]
//   [--loader [--title "Game name"]]
//   --loader: fullscreen loading screen (Steam hero art + logo, spinner, status, learned progress bar)
//   until the game's window appears.
//   --hide-launchers (chain mode): hides Epic/publisher launcher windows while the game loads; if the
//   game hasn't started after --hide-for seconds they are shown again (sign-in or update may need input).
//   Launched from Big Picture -> Big Picture is brought back when the game ends.
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

    // ---- hiding launcher windows (console-like: only Big Picture and the game are ever visible) ----
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32First(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32Next(IntPtr snap, ref PROCESSENTRY32 e);
    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);

    // pids of everything started (directly or indirectly) by root, except the game and anti-cheat
    static HashSet<uint> Descendants(int root, string game)
    {
        var parent = new Dictionary<uint, uint>(); var name = new Dictionary<uint, string>();
        IntPtr snap = CreateToolhelp32Snapshot(2 /* TH32CS_SNAPPROCESS */, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return new HashSet<uint>();
        try
        {
            var e = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
            for (bool ok = Process32First(snap, ref e); ok; ok = Process32Next(snap, ref e))
            { parent[e.th32ProcessID] = e.th32ParentProcessID; name[e.th32ProcessID] = e.szExeFile ?? ""; }
        }
        finally { CloseHandle(snap); }
        var set = new HashSet<uint> { (uint)root };
        for (bool grew = true; grew; )
        {
            grew = false;
            foreach (var kv in parent)
                if (!set.Contains(kv.Key) && set.Contains(kv.Value) && kv.Key != kv.Value) { set.Add(kv.Key); grew = true; }
        }
        set.RemoveWhere(pid =>
        {
            string n = Path.GetFileNameWithoutExtension(name.ContainsKey(pid) ? name[pid] : "");
            return n.Equals(game, StringComparison.OrdinalIgnoreCase) || n.EndsWith("_BE", StringComparison.OrdinalIgnoreCase);
        });
        return set;
    }

    static readonly List<IntPtr> hidden = new List<IntPtr>();
    static void HideWindowsOf(HashSet<uint> pids)
    {
        EnumWindows((hwnd, l) =>
        {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pids.Contains(pid) && IsWindowVisible(hwnd))
            {
                ShowWindow(hwnd, 0 /* SW_HIDE */);
                if (!hidden.Contains(hwnd)) { hidden.Add(hwnd); Log("hid a launcher window (pid " + pid + ")"); }
            }
            return true;
        }, IntPtr.Zero);
    }
    // ---- loading screen helpers ----
    // the shortcut's art from Steam's grid folder (Steam tells us the shortcut via SteamGameId)
    // backgrounds: every picture in art\<appid>\ next to the exe (the Shortcut Maker fills it), plus Steam's hero
    static void FindArt(out List<string> backgrounds, out string logo)
    {
        backgrounds = new List<string>(); logo = null; string hero = null;
        try
        {
            ulong gid; if (!ulong.TryParse(Environment.GetEnvironmentVariable("SteamGameId") ?? "", out gid)) return;
            uint appid = (uint)(gid >> 32); if (appid == 0) return;
            string artDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "art", appid.ToString());
            if (Directory.Exists(artDir))
                foreach (var f in Directory.GetFiles(artDir))
                {
                    string ext = Path.GetExtension(f).ToLowerInvariant();
                    if (ext == ".jpg" || ext == ".jpeg" || ext == ".png")
                    {
                        if (Path.GetFileNameWithoutExtension(f).Equals("logo", StringComparison.OrdinalIgnoreCase)) logo = f; else backgrounds.Add(f);
                    }
                }
            string steam = (string)Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null);
            if (steam == null) return;
            string user = Convert.ToString(Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam\ActiveProcess", "ActiveUser", 0));
            var dirs = new List<string>();
            string ud = Path.Combine(steam.Replace('/', '\\'), "userdata");
            if (user != "0") dirs.Add(Path.Combine(ud, user, "config", "grid"));
            if (Directory.Exists(ud)) foreach (var d in Directory.GetDirectories(ud)) dirs.Add(Path.Combine(d, "config", "grid"));
            foreach (var g in dirs)
            {
                if (hero == null) foreach (var n in new[] { appid + "_hero.jpg", appid + "_hero.png", appid + ".jpg", appid + ".png" }) { var p = Path.Combine(g, n); if (File.Exists(p)) { hero = p; break; } }
                if (logo == null) { var p = Path.Combine(g, appid + "_logo.png"); if (File.Exists(p)) logo = p; }
                if (hero != null && logo != null) break;
            }
        }
        catch { }
        if (hero != null && !backgrounds.Contains(hero)) backgrounds.Add(hero);
    }

    // learned load time per game (seconds until its window appears)
    static string TimesPath { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "loadtimes.txt"); } }
    static double GetLoadTime(string game)
    {
        try { foreach (var l in File.ReadAllLines(TimesPath)) { var p = l.Split('='); double v; if (p.Length == 2 && p[0].Equals(game, StringComparison.OrdinalIgnoreCase) && double.TryParse(p[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) return v; } }
        catch { }
        return 0;
    }
    static void SaveLoadTime(string game, double secs)
    {
        try
        {
            double old = GetLoadTime(game);
            double v = old > 0 ? old * 0.6 + secs * 0.4 : secs;   // smooth over launches
            var lines = new List<string>();
            if (File.Exists(TimesPath)) foreach (var l in File.ReadAllLines(TimesPath)) if (!l.StartsWith(game + "=", StringComparison.OrdinalIgnoreCase)) lines.Add(l);
            lines.Add(game + "=" + v.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture));
            File.WriteAllLines(TimesPath, lines.ToArray());
        }
        catch { }
    }

    // "what is happening now", from the newest interesting process in the chain
    static string StageText(Process epic, string game)
    {
        if (Find(game).Length > 0) return "Loading game...";
        if (epic == null) return "Starting...";
        string best = null; DateTime bestT = DateTime.MinValue; bool antiCheat = false;
        foreach (var p in Process.GetProcesses())
            try { if (p.ProcessName.EndsWith("_BE", StringComparison.OrdinalIgnoreCase) && p.ProcessName.StartsWith(game, StringComparison.OrdinalIgnoreCase)) antiCheat = true; } catch { }
        try
        {
            foreach (var pid in Descendants(epic.Id, "\0"))
            {
                try
                {
                    var p = Process.GetProcessById((int)pid);
                    string n = p.ProcessName;
                    if (n.EndsWith("_BE", StringComparison.OrdinalIgnoreCase) || n.StartsWith("BEService", StringComparison.OrdinalIgnoreCase)) { antiCheat = true; continue; }
                    string path = ProcPath(p); if (path.Length == 0) continue;
                    string desc = FileVersionInfo.GetVersionInfo(path).FileDescription ?? "";
                    string low = (n + " " + desc).ToLowerInvariant();
                    if (low.Contains("epicgameslauncher") || low.Contains("webview") || low.Contains("helper") || low.Contains("handler") || low.Contains("service") || low.Contains("crash") || low.Contains("redirector") || desc.Trim().Length == 0) continue;
                    DateTime t = p.StartTime;
                    if (t > bestT) { bestT = t; best = desc.Trim(); }
                }
                catch { }
            }
        }
        catch { }
        if (antiCheat) return "Starting anti-cheat...";
        if (best != null) return "Starting " + best + "...";
        return "Connecting to Epic Games...";
    }
    // anti-cheat protected games refuse process queries (MainWindowHandle stays 0), so look at the windows themselves
    static bool HasVisibleWindow(string game)
    {
        var pids = new HashSet<uint>();
        foreach (var p in Find(game)) pids.Add((uint)p.Id);
        if (pids.Count == 0) return false;
        bool found = false;
        EnumWindows((hwnd, l) =>
        {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if (pids.Contains(pid) && IsWindowVisible(hwnd)) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static void UnhideAll()
    {
        foreach (var h in hidden) ShowWindow(h, 5 /* SW_SHOW */);
        if (hidden.Count > 0) Log("showed " + hidden.Count + " launcher window(s) again");
        hidden.Clear();
    }

    static int Main(string[] args)
    {
        // log next to the exe (not under AppData, which some apps virtualize per-package)
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        logPath = Path.Combine(dir, "log.txt");
        try { if (File.Exists(logPath) && new FileInfo(logPath).Length > 512 * 1024) File.Delete(logPath); } catch { }

        string uri = null, game = null, epicExe = null; var killPaths = new List<string>();
        int timeout = 300, grace = 8, hideFor = 90; bool dry = false, chain = false, hide = false, loader = false;
        string title = null;
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
            else if (a == "--hide-launchers") hide = true;
            else if (a == "--loader") loader = true;
            else if (a == "--title" && next != null) { title = next; i++; }
            else if (a == "--hide-for" && next != null) { int.TryParse(next, out hideFor); i++; }
            else if (a == "--dry-run") dry = true;
        }
        if (game != null && game.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) game = game.Substring(0, game.Length - 4);

        Log("---- start: game=" + game + " timeout=" + timeout + "s chain=" + chain + " dry=" + dry);
        Log("steam overlay in this launcher: " + (HasOverlay(Process.GetCurrentProcess()) ? "yes" : "no"));
        if (string.IsNullOrEmpty(uri) || string.IsNullOrEmpty(game)) { Log("ERROR: --uri and --game are required"); return 2; }
        if (chain && epicExe == null) epicExe = EpicExeFromRegistry();
        if (chain && (epicExe == null || !File.Exists(epicExe))) { Log("chain: Epic exe not found (" + epicExe + "); falling back to normal launch"); chain = false; }

        // loading screen (covers Big Picture / desktop until the game's window shows up)
        var total = Stopwatch.StartNew();
        double expected = GetLoadTime(game);
        loader = loader && !dry && Find(game).Length == 0;
        if (loader)
        {
            List<string> bgs; string logoArt; FindArt(out bgs, out logoArt);
            Loader.Status = "Starting...";
            Loader.Progress = expected > 0 ? 0f : -1f;
            Loader.Show(title ?? game, bgs, logoArt);
            Log("loader shown (" + bgs.Count + " background(s)" + (logoArt != null ? " + logo" : "") + ", expected " + (int)expected + "s)");
        }

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
        // Big Picture started us -> come back to it at the end
        bool fromBigPicture = Environment.GetEnvironmentVariable("SteamGamepadUI") != null || Environment.GetEnvironmentVariable("SteamTenfoot") != null;
        hide = hide && chain && epic != null && !dry;
        var sw = Stopwatch.StartNew();
        Action updateLoader = () =>
        {
            if (!loader || !Loader.Visible) return;
            Loader.Status = StageText(epic, game);
            if (expected > 0) Loader.Progress = (float)(0.95 * Math.Min(1.0, total.Elapsed.TotalSeconds / expected));
        };
        while (Find(game).Length == 0)
        {
            if (sw.Elapsed.TotalSeconds > timeout) { UnhideAll(); if (loader) Loader.Close(); Log("game did not start within " + timeout + "s; exiting"); return 1; }
            if (hide)
            {
                if (sw.Elapsed.TotalSeconds < hideFor) { try { HideWindowsOf(Descendants(epic.Id, game)); } catch { } }
                else
                {
                    Log("game not started after " + hideFor + "s; showing launcher windows (sign-in or update may need you)");
                    UnhideAll(); hide = false;
                    if (loader) { Loader.Close(); loader = false; }
                }
            }
            updateLoader();
            Thread.Sleep(hide || loader ? 250 : 1000);
        }
        Log("game running after " + (int)sw.Elapsed.TotalSeconds + "s");

        // keep hiding launchers for a few seconds, and keep the loading screen up until the game's window appears
        var after = Stopwatch.StartNew();
        while (Find(game).Length > 0)
        {
            bool hiding = hide && after.Elapsed.TotalSeconds < 10;
            if (hiding) { try { HideWindowsOf(Descendants(epic.Id, game)); } catch { } }
            if (loader && Loader.Visible)
            {
                if (HasVisibleWindow(game))
                {
                    SaveLoadTime(game, total.Elapsed.TotalSeconds);
                    Log("game window up after " + (int)total.Elapsed.TotalSeconds + "s; closing loader");
                    Loader.Progress = 1f; Loader.Status = "Ready"; Thread.Sleep(300);
                    Loader.Close();
                }
                else if (after.Elapsed.TotalSeconds > 120) { Log("no game window after 120s; closing loader"); Loader.Close(); }
                else updateLoader();
            }
            if (!hiding && !(loader && Loader.Visible)) break;
            Thread.Sleep(250);
        }
        if (loader) Loader.Close();
        // report which processes in the chain carry Steam's overlay (the game itself may refuse inspection under anti-cheat)
        Thread.Sleep(5000);
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
        if (fromBigPicture && !dry)
        {
            try { Process.Start(new ProcessStartInfo("steam://open/bigpicture") { UseShellExecute = true }); Log("back to Big Picture"); } catch { }
        }
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
