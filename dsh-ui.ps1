#requires -version 5.1
<#
  dsh-ui (Windows) — 给 agent 用的 Windows 桌面操作原语，macOS 版 dsh-ui.swift 的等价实现。

  设计目标与 macOS 版一致：真实 HID 事件（SendInput）、带坐标映射的截图、
  两条互补的定位通道（UI Automation 树 / 屏幕 OCR）、可验证（wait-for / diff）、
  以及审计日志 + 拦截名单 + 干跑三道安全机制。

  命令面见 README-WINDOWS / docs/REFERENCE-WINDOWS.md；给 agent 的规范见 skill-win/SKILL.md。

  ⚠ 本文件必须以 **UTF-8 with BOM** 保存：Windows PowerShell 5.1 读取无 BOM 的 UTF-8
  脚本时会按系统 ANSI 代码页解码，文件里的中文会变成乱码。

  退出码：0 成功 / 1 未命中或超时 / 2 用法错误 / 3 被拦截名单拒绝。
#>

$ErrorActionPreference = 'Continue'
$script:Version = '1.0.0'

# ---------------------------------------------------------------- argv ----
# 用 -File 调用时 PowerShell 会把 `--dry`、`-R`、`-1010,150,80,260` 原样放进 $args；
# 但用 `& .\dsh-ui.ps1 ...` 在会话内调用时，裸数字会被绑定成 Int32、`--x` 会被
# 当成位置参数。两条路径都收敛成字符串数组。
$script:Argv = @()
foreach ($a in $args) { $script:Argv += [string]$a }
try {
  $raw = [Environment]::GetCommandLineArgs()
  $idx = -1
  for ($i = $raw.Count - 1; $i -ge 0; $i--) {
    $s = [string]$raw[$i]
    if ($s -match '(?i)dsh-ui\.ps1$' -and $s -notmatch '[&|;]') { $idx = $i; break }
  }
  if ($idx -ge 0 -and $idx -lt $raw.Count - 1) {
    $fromCli = @()
    for ($i = $idx + 1; $i -lt $raw.Count; $i++) { $fromCli += [string]$raw[$i] }
    if ($fromCli.Count -gt 0) { $script:Argv = $fromCli }
  }
} catch { }

# ------------------------------------------------------- console/state ----
# 只在输出被重定向时强制 UTF-8：直接跑在旧式控制台里时保留系统代码页，避免中文变问号。
try {
  if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }
  if ([Console]::IsInputRedirected) { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false }
} catch { }
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

$script:StateDir = Join-Path $env:LOCALAPPDATA 'dsh-ui'
$script:AuditFile = Join-Path $script:StateDir 'audit.log'
$script:DenyFile = Join-Path $script:StateDir 'denylist.txt'
$script:ShotDir = Join-Path $env:TEMP 'dsh-ui-shots'
$script:Dry = $false

function Initialize-StateDirs {
  foreach ($d in @($script:StateDir, $script:ShotDir)) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Force -Path $d) }
  }
  if (-not (Test-Path -LiteralPath $script:DenyFile)) {
    $defaults = @(
      '# dsh-ui 拦截名单：命中行（不区分大小写，子串匹配进程名/应用名/窗口标题）拒绝执行并返回 exit 3',
      '1password', 'keepass', 'bitwarden', 'lastpass', 'keeper', 'dashlane',
      'enpass', 'nordpass', 'roboform', 'securityhealth', 'credentialuibroker'
    )
    [System.IO.File]::WriteAllText($script:DenyFile, (($defaults -join "`r`n") + "`r`n"), $script:Utf8NoBom)
  }
}

# -------------------------------------------------------- exit helpers ----
function Write-Out { param([string]$Text) [Console]::Out.WriteLine($Text) }
function Write-ErrLine { param([string]$Text) try { [Console]::Error.WriteLine($Text) } catch { Write-Out $Text } }

function Fail {
  param([int]$Code, [string]$Message)
  Write-ErrLine ("error: " + $Message)
  # 抛异常而不是 exit：这样每层都能写审计日志（macOS 版对用法错误也记一条）
  throw ([DshExitException]::new($Code, $Message))
}
function Fail-Usage { param([string]$Message) Fail 2 ("用法错误：" + $Message + "`n运行 dsh-ui --help 查看命令。") }

# macOS 版把审计写在每次命令结束时；这里用 try/finally 保证异常路径也落盘。
function Add-Audit {
  param([string]$Command, [int]$Code)
  try {
    Initialize-StateDirs
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $line = "{0} code={1} pid={2} dry={3} cmd={4}" -f $stamp, $Code, $PID, ($(if ($script:Dry) { 1 } else { 0 })), $Command
    [System.IO.File]::AppendAllText($script:AuditFile, $line + "`r`n", $script:Utf8NoBom)
  } catch { }
}

# ------------------------------------------------------------ denylist ----
function Get-DenyEntries {
  Initialize-StateDirs
  $out = @()
  try {
    foreach ($ln in [System.IO.File]::ReadAllLines($script:DenyFile, [System.Text.Encoding]::UTF8)) {
      $t = $ln.Trim()
      if ($t -eq '' -or $t.StartsWith('#')) { continue }
      $out += $t.ToLowerInvariant()
    }
  } catch { }
  return $out
}

function Test-Denied {
  param([string]$ProcessName, [string]$AppName, [string]$Title)
  $hay = @()
  foreach ($s in @($ProcessName, $AppName, $Title)) { if ($s) { $hay += $s.ToLowerInvariant() } }
  if ($hay.Count -eq 0) { return $null }
  foreach ($d in Get-DenyEntries) {
    foreach ($h in $hay) { if ($h.Contains($d)) { return $d } }
  }
  return $null
}

# 拦截判定用在两个地方：鼠标动作看「落点下的窗口」，键盘动作看「当前前台窗口」。
function Assert-NotDenied {
  param([string]$Where, [IntPtr]$Hwnd)
  if ($Hwnd -eq [IntPtr]::Zero) { return }
  $info = Get-WindowOwner -Hwnd $Hwnd
  $hit = Test-Denied -ProcessName $info.Process -AppName $info.App -Title $info.Title
  if ($hit) {
    Fail 3 ("被拦截名单拒绝（$Where 命中 `"$hit`"：$($info.App) / $($info.Process)）。" +
            "如确需操作，请编辑 " + $script:DenyFile)
  }
}

# ------------------------------------------------------------ interop ----
$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class DshWin
{
    // ---- structs -------------------------------------------------------
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct MONITORINFOEX {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
    }

    // ---- constants -----------------------------------------------------
    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000, MOUSEEVENTF_VIRTUALDESK = 0x4000;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001, KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004;
    public const int SW_HIDE = 0, SW_SHOWNORMAL = 1, SW_SHOWMINIMIZED = 2, SW_SHOWMAXIMIZED = 3,
                     SW_SHOWNOACTIVATE = 4, SW_SHOW = 5, SW_MINIMIZE = 6, SW_RESTORE = 9, SW_MAXIMIZE = 3;
    public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    public const int DWMWA_CLOAKED = 14;

    // ---- p/invoke ------------------------------------------------------
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetActiveWindow();
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFOEX mi);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr data);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool QueryFullProcessImageNameW(IntPtr h, uint flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    public delegate bool MonitorEnumProc(IntPtr mon, IntPtr hdc, ref RECT rect, IntPtr data);
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr data);

    // ---- dpi -----------------------------------------------------------
    public static bool SetDpiAwareness()
    {
        try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); }   // PER_MONITOR_AWARE_V2
        catch { return false; }
    }

    // ---- monitors ------------------------------------------------------
    public class MonInfo {
        public int Index; public string Device = ""; public int Left, Top, Right, Bottom;
        public int WorkLeft, WorkTop, WorkRight, WorkBottom;
        public uint Dpi; public double Scale; public bool Primary;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
    }

    public static List<MonInfo> Monitors()
    {
        var list = new List<MonInfo>();
        MonitorEnumProc cb = delegate(IntPtr mon, IntPtr hdc, ref RECT r, IntPtr data) {
            var mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfoW(mon, ref mi)) {
                var info = new MonInfo();
                info.Device = mi.szDevice;
                info.Left = mi.rcMonitor.Left; info.Top = mi.rcMonitor.Top;
                info.Right = mi.rcMonitor.Right; info.Bottom = mi.rcMonitor.Bottom;
                info.WorkLeft = mi.rcWork.Left; info.WorkTop = mi.rcWork.Top;
                info.WorkRight = mi.rcWork.Right; info.WorkBottom = mi.rcWork.Bottom;
                info.Primary = (mi.dwFlags & 1) != 0;
                uint dx = 96, dy = 96;
                try { if (GetDpiForMonitor(mon, 0, out dx, out dy) != 0) { dx = 96; } } catch { dx = 96; }
                info.Dpi = dx; info.Scale = Math.Round(dx / 96.0, 4);
                lock (list) { list.Add(info); }
            }
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        list.Sort(delegate(MonInfo a, MonInfo b) {
            if (a.Primary != b.Primary) { return a.Primary ? -1 : 1; }
            if (a.Left != b.Left) { return a.Left.CompareTo(b.Left); }
            return a.Top.CompareTo(b.Top);
        });
        for (int i = 0; i < list.Count; i++) { list[i].Index = i + 1; }
        return list;
    }

    public static MonInfo MonitorAt(int x, int y)
    {
        var p = new POINT(); p.X = x; p.Y = y;
        IntPtr mon = MonitorFromPoint(p, 2);   // NEAREST
        var all = Monitors();
        foreach (var m in all) {
            if (x >= m.Left && x < m.Right && y >= m.Top && y < m.Bottom) { return m; }
        }
        // 落在显示器之间的缝里：交给枚举顺序的第一个（主屏）
        return all.Count > 0 ? all[0] : null;
    }

    public static MonInfo MonitorOfWindow(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) { return null; }
        return MonitorAt((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2);
    }

    // ---- process / window info ----------------------------------------
    public static string ProcessPath(int pid)
    {
        IntPtr h = OpenProcess(0x1000, false, pid);   // QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) { return ""; }
        try {
            var sb = new StringBuilder(1024);
            int size = sb.Capacity;
            if (QueryFullProcessImageNameW(h, 0, sb, ref size)) { return sb.ToString(0, size); }
            return "";
        } finally { CloseHandle(h); }
    }

    static readonly Dictionary<int, string[]> procCache = new Dictionary<int, string[]>();
    public static string[] ProcessNames(int pid)
    {
        lock (procCache) { if (procCache.ContainsKey(pid)) { return procCache[pid]; } }
        string path = ProcessPath(pid);
        string exe = "", desc = "";
        if (path.Length > 0) {
            try { exe = System.IO.Path.GetFileNameWithoutExtension(path); } catch { }
            try {
                var vi = FileVersionInfo.GetVersionInfo(path);
                desc = vi.FileDescription;
                if (desc == null) { desc = ""; }
            } catch { }
        }
        if (exe.Length == 0) {
            try { exe = Process.GetProcessById(pid).ProcessName; } catch { exe = "pid" + pid; }
        }
        var res = new string[] { exe, desc };
        lock (procCache) { procCache[pid] = res; }
        return res;
    }

    public static string WindowTitle(IntPtr h)
    {
        int len = GetWindowTextLengthW(h);
        var sb = new StringBuilder(len + 2);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string WindowClass(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static bool IsCloaked(IntPtr h)
    {
        try { int v; if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out v, 4) == 0) { return v != 0; } } catch { }
        return false;
    }

    public class WinInfo {
        public IntPtr Hwnd; public int Pid; public string Process = ""; public string App = "";
        public string Title = ""; public string Class = "";
        public int Left, Top, Right, Bottom;
        public bool Minimized, Maximized, Foreground, Visible;
        public int Monitor;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
        public int CenterX { get { return (Left + Right) / 2; } }
        public int CenterY { get { return (Top + Bottom) / 2; } }
    }

    public static WinInfo Describe(IntPtr h, bool useNormalRect)
    {
        var w = new WinInfo();
        w.Hwnd = h;
        w.Title = WindowTitle(h);
        w.Class = WindowClass(h);
        w.Pid = (int)GetWindowThreadProcessId(h, IntPtr.Zero);
        var names = ProcessNames(w.Pid);
        w.Process = names[0]; w.App = names[1].Length > 0 ? names[1] : names[0];
        w.Visible = IsWindowVisible(h);
        w.Minimized = IsIconic(h);
        w.Maximized = IsZoomed(h);
        w.Foreground = (GetForegroundWindow() == h);
        RECT r;
        if (GetWindowRect(h, out r)) { w.Left = r.Left; w.Top = r.Top; w.Right = r.Right; w.Bottom = r.Bottom; }
        if (useNormalRect && w.Minimized) {
            var wp = new WINDOWPLACEMENT(); wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (GetWindowPlacement(h, ref wp)) {
                w.Left = wp.rcNormalPosition.Left; w.Top = wp.rcNormalPosition.Top;
                w.Right = wp.rcNormalPosition.Right; w.Bottom = wp.rcNormalPosition.Bottom;
            }
        }
        var mon = MonitorAt((w.Left + w.Right) / 2, (w.Top + w.Bottom) / 2);
        w.Monitor = mon == null ? 0 : mon.Index;
        return w;
    }

    // 顶层、可见、有标题、未被 DWM 隐藏的窗口 —— 与 macOS 版 win list 的口径一致。
    public static List<WinInfo> TopWindows(bool includeMinimized)
    {
        var list = new List<WinInfo>();
        EnumWindowsProc cb = delegate(IntPtr h, IntPtr data) {
            if (!IsWindowVisible(h)) { return true; }
            if (IsCloaked(h)) { return true; }
            string title = WindowTitle(h);
            if (title.Length == 0) { return true; }
            if (!includeMinimized && IsIconic(h)) { return true; }
            try { list.Add(Describe(h, true)); } catch { }
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        // 前台窗口排最前，其余按 z 序（EnumWindows 本身就是 z 序）
        list.Sort(delegate(WinInfo a, WinInfo b) {
            if (a.Foreground != b.Foreground) { return a.Foreground ? -1 : 1; }
            return 0;
        });
        return list;
    }

    public static bool IsPidValid(int pid)
    {
        if (pid <= 0) { return false; }
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) { return false; }
        CloseHandle(h);
        return true;
    }

    // 「原始」窗口信息：只读窗口自身，不碰进程 —— 进程归属由 PowerShell 侧解析，
    // 因为受限令牌下 GetWindowThreadProcessId 可能返回无效 PID（UIA 的 ProcessId 才是真的）。
    public class RawWin {
        public IntPtr Hwnd; public string Title = ""; public string Class = "";
        public int Left, Top, Right, Bottom;
        public bool Minimized, Maximized, Foreground, Visible;
    }

    public static RawWin RawDescribe(IntPtr h)
    {
        var w = new RawWin();
        w.Hwnd = h;
        w.Title = WindowTitle(h);
        w.Class = WindowClass(h);
        w.Visible = IsWindowVisible(h);
        w.Minimized = IsIconic(h);
        w.Maximized = IsZoomed(h);
        w.Foreground = (GetForegroundWindow() == h);
        RECT r;
        if (GetWindowRect(h, out r)) { w.Left = r.Left; w.Top = r.Top; w.Right = r.Right; w.Bottom = r.Bottom; }
        if (w.Minimized) {
            var wp = new WINDOWPLACEMENT(); wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (GetWindowPlacement(h, ref wp)) {
                w.Left = wp.rcNormalPosition.Left; w.Top = wp.rcNormalPosition.Top;
                w.Right = wp.rcNormalPosition.Right; w.Bottom = wp.rcNormalPosition.Bottom;
            }
        }
        return w;
    }

    public static List<RawWin> RawWindows(bool includeMinimized)
    {
        var list = new List<RawWin>();
        EnumWindowsProc cb = delegate(IntPtr h, IntPtr data) {
            if (!IsWindowVisible(h)) { return true; }
            if (IsCloaked(h)) { return true; }
            if (WindowTitle(h).Length == 0) { return true; }
            if (!includeMinimized && IsIconic(h)) { return true; }
            string cls = WindowClass(h);
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "NarratorHelperWindow") { return true; }
            try { list.Add(RawDescribe(h)); } catch { }
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        list.Sort(delegate(RawWin a, RawWin b) {
            if (a.Foreground != b.Foreground) { return a.Foreground ? -1 : 1; }
            return 0;
        });
        return list;
    }

    public static IntPtr TopLevelAt(int x, int y)    {
        var p = new POINT(); p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) { return IntPtr.Zero; }
        IntPtr root = GetAncestor(h, 2);   // GA_ROOT
        return root == IntPtr.Zero ? h : root;
    }

    public static bool ForceForeground(IntPtr h)
    {
        if (!IsWindow(h)) { return false; }
        if (GetForegroundWindow() == h) { return true; }
        if (IsIconic(h)) { ShowWindow(h, SW_RESTORE); }
        uint cur = GetCurrentThreadId();
        uint target = GetWindowThreadProcessId(h, IntPtr.Zero);
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        bool a1 = false, a2 = false;
        try {
            if (target != 0 && target != cur) { a1 = AttachThreadInput(cur, target, true); }
            if (fg != 0 && fg != cur) { a2 = AttachThreadInput(cur, fg, true); }
            BringWindowToTop(h);
            SetForegroundWindow(h);
        } finally {
            if (a1) { AttachThreadInput(cur, target, false); }
            if (a2) { AttachThreadInput(cur, fg, false); }
        }
        return GetForegroundWindow() == h;
    }

    public static int[] CursorPos()
    {
        POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y };
    }

    // ---- input ---------------------------------------------------------
    static int VSLeft() { return GetSystemMetrics(76); }
    static int VSTop() { return GetSystemMetrics(77); }
    static int VSWidth() { return GetSystemMetrics(78); }
    static int VSHeight() { return GetSystemMetrics(79); }

    static void Send(INPUT[] inputs)
    {
        int size = Marshal.SizeOf(typeof(INPUT));
        uint sent = SendInput((uint)inputs.Length, inputs, size);
        if (sent != inputs.Length) {
            throw new Exception("SendInput 只投递了 " + sent + "/" + inputs.Length + " 个事件（可能被 UIPI 拦截：目标以管理员权限运行？）");
        }
    }

    static INPUT MouseInput(uint flags, int dx, int dy, uint data)
    {
        var i = new INPUT();
        i.type = INPUT_MOUSE;
        i.u.mi.dx = dx; i.u.mi.dy = dy; i.u.mi.mouseData = data; i.u.mi.dwFlags = flags;
        return i;
    }

    public static void MouseMove(int x, int y)
    {
        int w = VSWidth(), h = VSHeight();
        int vx = x - VSLeft(), vy = y - VSTop();
        int nx = (int)Math.Round(vx * 65535.0 / Math.Max(1, w - 1));
        int ny = (int)Math.Round(vy * 65535.0 / Math.Max(1, h - 1));
        Send(new INPUT[] { MouseInput(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny, 0) });
    }

    public static void MouseDown(string button)
    {
        uint f = button == "right" ? MOUSEEVENTF_RIGHTDOWN : (button == "middle" ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_LEFTDOWN);
        Send(new INPUT[] { MouseInput(f, 0, 0, 0) });
    }

    public static void MouseUp(string button)
    {
        uint f = button == "right" ? MOUSEEVENTF_RIGHTUP : (button == "middle" ? MOUSEEVENTF_MIDDLEUP : MOUSEEVENTF_LEFTUP);
        Send(new INPUT[] { MouseInput(f, 0, 0, 0) });
    }

    public static void MouseWheel(int delta, bool horizontal)
    {
        uint f = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
        Send(new INPUT[] { MouseInput(f, 0, 0, unchecked((uint)delta)) });
    }

    public static void KeyVk(ushort vk, bool down, bool extended)
    {
        var i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = 0;
        i.u.ki.dwFlags = (down ? 0u : KEYEVENTF_KEYUP) | (extended ? KEYEVENTF_EXTENDEDKEY : 0u);
        Send(new INPUT[] { i });
    }

    // KEYEVENTF_UNICODE：绕过输入法与键盘布局，直接投递 UTF-16 码元（中文可用）。
    public static void TypeUnicode(string text)
    {
        var list = new List<INPUT>();
        foreach (char ch in text) {
            var d = new INPUT(); d.type = INPUT_KEYBOARD; d.u.ki.wVk = 0; d.u.ki.wScan = ch; d.u.ki.dwFlags = KEYEVENTF_UNICODE;
            var u = new INPUT(); u.type = INPUT_KEYBOARD; u.u.ki.wVk = 0; u.u.ki.wScan = ch; u.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            list.Add(d); list.Add(u);
        }
        if (list.Count > 0) { Send(list.ToArray()); }
    }

    public static short VkFor(char ch) { return VkKeyScanW(ch); }
    public static uint DoubleClickTime() { return GetDoubleClickTime(); }
}
'@

function Initialize-Native {
  if (-not ('DshWin' -as [type])) {
    Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop
  }
  # 必须在任何坐标/窗口调用之前设置：否则读到的是 DPI 虚拟化后的逻辑像素，
  # 与 SendInput 使用的物理像素对不上（实测差 1.25 倍）。
  $script:DpiAware = [bool][DshWin]::SetDpiAwareness()
}

# ------------------------------------------------ window helpers (PS) ----
function Get-WindowOwner {
  param([IntPtr]$Hwnd)
  $w = [DshWin]::Describe($Hwnd, $false)
  return [pscustomobject]@{
    Hwnd    = $Hwnd
    Pid     = $w.Pid
    Process = $w.Process
    App     = $w.App
    Title   = $w.Title
    Class   = $w.Class
    Rect    = @($w.Left, $w.Top, $w.Width, $w.Height)
  }
}

function Get-CursorPoint { $c = [DshWin]::CursorPos(); return @([int]$c[0], [int]$c[1]) }

function Get-PrimaryMonitor {
  foreach ($m in [DshWin]::Monitors()) { if ($m.Primary) { return $m } }
  return ([DshWin]::Monitors())[0]
}

# 干跑：只打印将要执行的动作，不产生任何副作用。
function Invoke-Dry {
  param([string]$What)
  Write-Out ("dry: " + $What)
  return 0
}

function Format-Rect { param($X, $Y, $W, $H) return "($X,$Y) ${W}x${H}" }

# =========================================================== 图像层 ====
# 像素级比较、稳定性哈希都放在 C# 里：1920x1080 是 200 万像素，纯 PowerShell 循环不可用。
$script:ImageSource = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class DshImg
{
    public class DiffResult {
        public int Changed; public int MinX; public int MinY; public int MaxX; public int MaxY;
        public DiffResult() { MinX = int.MaxValue; MinY = int.MaxValue; MaxX = -1; MaxY = -1; }
    }

    public static Bitmap Load(string path)
    {
        using (var src = new Bitmap(path)) {
            var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(dst)) { g.DrawImageUnscaled(src, 0, 0); }
            return dst;
        }
    }

    public static void Save(Bitmap bmp, string path)
    {
        bmp.Save(path, ImageFormat.Png);
    }

    static byte[] Bytes(Bitmap bmp, out int stride)
    {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            stride = Math.Abs(data.Stride);
            var buf = new byte[stride * bmp.Height];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            return buf;
        } finally { bmp.UnlockBits(data); }
    }

    // mac 版口径：|ΔR|+|ΔG|+|ΔB| > threshold（严格大于），忽略 alpha
    public static DiffResult Diff(Bitmap a, Bitmap b, int threshold, int x0, int y0, int x1, int y1)
    {
        var r = new DiffResult();
        if (a.Width != b.Width || a.Height != b.Height) { throw new Exception("尺寸不同"); }
        int sa, sb;
        byte[] ba = Bytes(a, out sa), bb = Bytes(b, out sb);
        if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
        if (x1 > a.Width) x1 = a.Width; if (y1 > a.Height) y1 = a.Height;
        for (int y = y0; y < y1; y++) {
            int ra = y * sa, rb = y * sb;
            for (int x = x0; x < x1; x++) {
                int i = x * 4;
                int d = Math.Abs(ba[ra + i] - bb[rb + i]) + Math.Abs(ba[ra + i + 1] - bb[rb + i + 1]) + Math.Abs(ba[ra + i + 2] - bb[rb + i + 2]);
                if (d > threshold) {
                    r.Changed++;
                    if (x < r.MinX) r.MinX = x; if (x > r.MaxX) r.MaxX = x;
                    if (y < r.MinY) r.MinY = y; if (y > r.MaxY) r.MaxY = y;
                }
            }
        }
        return r;
    }

    public static long Hash(Bitmap bmp)
    {
        int stride;
        byte[] buf = Bytes(bmp, out stride);
        long h = 0;
        for (int i = 0; i < buf.Length; i++) { h = unchecked(h * 31 + buf[i]); }
        return h;
    }

    public static bool SameSize(Bitmap a, Bitmap b) { return a.Width == b.Width && a.Height == b.Height; }
}
'@

function Initialize-Image {
  if (-not ('DshImg' -as [type])) {
    Add-Type -AssemblyName System.Drawing
    # 先造一个 1x1 位图，逼 .NET 10 的 GDI+ 实现程序集（System.Private.Windows.GdiPlus）加载
    try { $tmp = New-Object System.Drawing.Bitmap 1, 1; $tmp.Dispose() } catch { }
    # 引用**已加载**的程序集路径：按名字引用 System.Drawing 只是转发门面（.NET 10 把
    # Rectangle 放进 System.Drawing.Primitives、GDI+ 实体放进 System.Private.Windows.GdiPlus），
    # 少引一个就是 CS1069/CS0012。这里把当前 AppDomain 里带路径的程序集都带上，
    # 但要剔除 .winmd（WinRT 元数据，csc 会报 0x80131047）与资源卫星程序集。
    $refs = @()
    foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
      try {
        $loc = $a.Location
        if (-not $loc) { continue }
        if ($loc -match '\.winmd$' -or $loc -match '\.resources\.dll$') { continue }
        if ($refs -contains $loc) { continue }
        $refs += $loc
      } catch { }
    }
    try {
      Add-Type -TypeDefinition $script:ImageSource -Language CSharp -ReferencedAssemblies $refs -ErrorAction Stop
    } catch {
      $first = $_.Exception.Message
      try {
        Add-Type -TypeDefinition $script:ImageSource -Language CSharp -ErrorAction Stop
      } catch {
        throw ("图像层编译失败。`n带引用: $first`n不带引用: " + $_.Exception.Message)
      }
    }
  }
}

# 图片进剪贴板要 STA：派生一个 Windows PowerShell（默认 STA）去做，避免把 WinForms 拖进 C# 编译
function Set-ClipboardImageFile {
  param([string]$Path)
  $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $ps51)) { $ps51 = 'powershell.exe' }
  $safe = $Path.Replace("'", "''")
  $cmd = "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; " +
         "`$img = [System.Drawing.Image]::FromFile('$safe'); " +
         "[System.Windows.Forms.Clipboard]::SetImage(`$img); `$img.Dispose(); 'ok'"
  $out = & $ps51 -NoProfile -STA -Command $cmd 2>&1
  if ($LASTEXITCODE -ne 0 -or ($out -join ' ') -notmatch 'ok') { throw (($out | Out-String).Trim()) }
}

# mac 的 fmt()：整数就打成整数，否则 %g
function Format-Num {
  param($V)
  $d = [double]$V
  if ($d -eq [math]::Round($d)) { return ([long]$d).ToString() }
  return $d.ToString('G6', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DisplayList {
  $out = @()
  foreach ($m in [DshWin]::Monitors()) {
    $out += [pscustomobject]@{
      Index     = [int]$m.Index
      Device    = [string]$m.Device
      Left      = [int]$m.Left
      Top       = [int]$m.Top
      Right     = [int]$m.Right
      Bottom    = [int]$m.Bottom
      Width     = [int]$m.Width
      Height    = [int]$m.Height
      WorkLeft  = [int]$m.WorkLeft
      WorkTop   = [int]$m.WorkTop
      WorkRight = [int]$m.WorkRight
      WorkBottom= [int]$m.WorkBottom
      Dpi       = [int]$m.Dpi
      Scale     = [double]$m.Scale
      Primary   = [bool]$m.Primary
    }
  }
  return $out
}

function Get-Display {
  param([int]$Index)
  foreach ($d in Get-DisplayList) { if ($d.Index -eq $Index) { return $d } }
  return $null
}

function Get-DisplayForPoint {
  param([int]$X, [int]$Y)
  $all = @(Get-DisplayList)
  foreach ($d in $all) { if ($X -ge $d.Left -and $X -lt $d.Right -and $Y -ge $d.Top -and $Y -lt $d.Bottom) { return $d } }
  if ($all.Count -gt 0) { return $all[0] }
  return $null
}

function Get-DisplayForRect {
  param([int]$X, [int]$Y, [int]$W, [int]$H)
  $all = @(Get-DisplayList)
  $cx = $X + [int]($W / 2); $cy = $Y + [int]($H / 2)
  foreach ($d in $all) { if ($cx -ge $d.Left -and $cx -lt $d.Right -and $cy -ge $d.Top -and $cy -lt $d.Bottom) { return $d } }
  return $null
}

function ConvertTo-Pt { param([int]$Px, [double]$Scale) if ($Scale -le 0) { return $Px } return [int]($Px / $Scale) }

# 截屏原语。坐标一律是全局左上物理像素（本进程已设 PerMonitorV2 DPI 感知）。
function New-Capture {
  param(
    [int]$X, [int]$Y, [int]$W, [int]$H,
    [switch]$WithCursor
  )
  Initialize-Image
  if ($W -le 0 -or $H -le 0) { throw "截图区域为空：${W}x${H}" }
  $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($W, $H)), [System.Drawing.CopyPixelOperation]::SourceCopy)
  } finally { $g.Dispose() }
  if ($WithCursor) { Add-CursorMark -Bmp $bmp -OffsetX $X -OffsetY $Y }
  return $bmp
}

# GDI 的 CopyFromScreen 不含光标，-C 时手工画一个箭头（与 macOS 版 -C 的目的一致）
function Add-CursorMark {
  param($Bmp, [int]$OffsetX, [int]$OffsetY)
  $c = Get-CursorPoint
  $cx = $c[0] - $OffsetX; $cy = $c[1] - $OffsetY
  if ($cx -lt 0 -or $cy -lt 0 -or $cx -ge $Bmp.Width -or $cy -ge $Bmp.Height) { return }
  $g = [System.Drawing.Graphics]::FromImage($Bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $pts = @(
      (New-Object System.Drawing.Point($cx, $cy)),
      (New-Object System.Drawing.Point($cx, ($cy + 17))),
      (New-Object System.Drawing.Point($cx + 4, ($cy + 13))),
      (New-Object System.Drawing.Point($cx + 7, ($cy + 19))),
      (New-Object System.Drawing.Point($cx + 10, ($cy + 17))),
      (New-Object System.Drawing.Point($cx + 7, ($cy + 11))),
      (New-Object System.Drawing.Point($cx + 12, ($cy + 11)))
    )
    $g.FillPolygon([System.Drawing.Brushes]::White, $pts)
    $g.DrawPolygon((New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1)), $pts)
  } finally { $g.Dispose() }
}

function Get-ShotPath {
  param([string]$OutPath)
  if ($OutPath) {
    $p = $OutPath
    if ($p.StartsWith('~')) { $p = Join-Path $HOME $p.Substring(1).TrimStart('\', '/') }
    return $p
  }
  Initialize-StateDirs
  $ms = [long]((Get-Date).ToUniversalTime() - (Get-Date '1970-01-01')).TotalMilliseconds
  $rand = Get-Random -Minimum 100 -Maximum 1000
  return (Join-Path $script:ShotDir ("shot-{0}-{1}.png" -f $ms, $rand))
}

function Get-DerivedPath {
  param([string]$Path, [string]$Suffix)
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $ext = [System.IO.Path]::GetExtension($Path)
  if (-not $ext) { return ($Path + $Suffix) }
  return (Join-Path $dir ($base + $Suffix + $ext))
}

function Add-ZoomOverlay {
  param([string]$Path, [double]$Factor)
  if ($Factor -le 1) { return $null }
  $src = [DshImg]::Load($Path)
  try {
    $w = [int]($src.Width * $Factor); $h = [int]($src.Height * $Factor)
    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    try {
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
      $g.DrawImage($src, 0, 0, $w, $h)
    } finally { $g.Dispose() }
    $out = Get-DerivedPath -Path $Path -Suffix ("-zoom{0}x" -f [int]$Factor)
    [DshImg]::Save($dst, $out)
    $dst.Dispose()
    return $out
  } finally { $src.Dispose() }
}

# 标尺：红线标 x、蓝线标 y、每 5 格加粗；数字是**全局左上坐标**。
# （macOS 版两条轴分别从上下两端步进，标注与线在中段才对齐；这里两条轴都从左上角步进，
#   线与数字始终对齐 —— 见 docs/REFERENCE-WINDOWS.md「与 macOS 版的差异」。）
function Add-GridOverlay {
  param([string]$Path, [double]$StepPt, [double]$Scale, [int]$OriginX, [int]$OriginY, [double]$Zoom = 1)
  # 步长按「点」算（与 macOS 版一致）：40pt 在 125% 缩放的屏上落成 50 个物理像素
  $pxStep = $StepPt * $Scale
  if ($pxStep -lt 6) { Write-Out ("  警告: 网格步长过小（{0}px），已跳过" -f [int]$pxStep); return $null }
  $src = [DshImg]::Load($Path)
  try {
    $w = $src.Width; $h = $src.Height
    $g = [System.Drawing.Graphics]::FromImage($src)
    try {
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
      $font = New-Object System.Drawing.Font('Consolas', 10, ([System.Drawing.FontStyle]::Bold), [System.Drawing.GraphicsUnit]::Pixel)
      $brush = [System.Drawing.Brushes]::White
      $labelBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(166, 0, 0, 0))
      $penRed = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 38, 38))
      $penBlue = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(38, 140, 255))
      $penRedThick = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(242, 38, 38), 1.5)
      $penBlueThick = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(242, 38, 140, 255), 1.5)
      $k = 0; $px = 0.0
      while ($px -le $w) {
        $gx = [int][math]::Round($OriginX + $px / $Zoom)
        $pen = $(if ($k % 5 -eq 0) { $penRedThick } else { $penRed })
        $g.DrawLine($pen, [single]($px + 0.5), 0, [single]($px + 0.5), $h)
        $text = "$gx"
        $sz = $g.MeasureString($text, $font)
        $lx = [single][math]::Min($px + 3, $w - $sz.Width - 1)
        $g.FillRectangle($labelBg, $lx, 1, $sz.Width, $sz.Height)
        $g.DrawString($text, $font, $brush, $lx, 1)
        $k++; $px += $pxStep
      }
      $k = 0; $py = 0.0
      while ($py -le $h) {
        $gy = [int][math]::Round($OriginY + $py / $Zoom)
        $pen = $(if ($k % 5 -eq 0) { $penBlueThick } else { $penBlue })
        $g.DrawLine($pen, 0, [single]($py + 0.5), $w, [single]($py + 0.5))
        $text = "$gy"
        $sz = $g.MeasureString($text, $font)
        $g.FillRectangle($labelBg, 1, [single][math]::Min($py + 2, $h - $sz.Height - 1), $sz.Width, $sz.Height)
        $g.DrawString($text, $font, $brush, 1, [single][math]::Min($py + 2, $h - $sz.Height - 1))
        $k++; $py += $pxStep
      }
      $font.Dispose(); $labelBg.Dispose(); $penRed.Dispose(); $penBlue.Dispose()
      $penRedThick.Dispose(); $penBlueThick.Dispose()
    } finally { $g.Dispose() }
    $out = Get-DerivedPath -Path $Path -Suffix '-grid'
    [DshImg]::Save($src, $out)
    return $out
  } finally { $src.Dispose() }
}

function Invoke-DisplaysCommand {
  param([string[]]$Rest)
  $json = $false
  foreach ($a in $Rest) { if ($a -eq '--json') { $json = $true } elseif ($a -ne '') { Fail-Usage "displays 不接受参数：$a" } }
  $disps = Get-DisplayList
  if ($json) {
    $arr = @()
    foreach ($d in $disps) {
      $arr += [ordered]@{
        index = $d.Index; device = $d.Device; primary = $d.Primary
        px = @($d.Width, $d.Height); pt = @((ConvertTo-Pt $d.Width $d.Scale), (ConvertTo-Pt $d.Height $d.Scale))
        scale = $d.Scale; dpi = $d.Dpi; origin_tl = @($d.Left, $d.Top)
        work_tl = @($d.WorkLeft, $d.WorkTop); work_px = @(($d.WorkRight - $d.WorkLeft), ($d.WorkBottom - $d.WorkTop))
      }
    }
    Write-Out ((ConvertTo-Json -InputObject ([ordered]@{ displays = $arr; virtual_tl = @([DshWin]::GetSystemMetrics(76), [DshWin]::GetSystemMetrics(77)); virtual_px = @([DshWin]::GetSystemMetrics(78), [DshWin]::GetSystemMetrics(79)) }) -Depth 6 -Compress))
    return 0
  }
  $main = Get-Display 1
  $mainH = 0; if ($main) { $mainH = $main.Height }
  Write-Out ("main height = {0}px  (Windows 全局坐标本来就是左上原点，无需换算)" -f $mainH)
  foreach ($d in $disps) {
    $ptW = ConvertTo-Pt $d.Width $d.Scale; $ptH = ConvertTo-Pt $d.Height $d.Scale
    $flags = ''
    if ($d.Primary) { $flags += ' primary' }
    Write-Out ("#{0} pt={1}x{2} px={3}x{4} scale={5} origin_tl=({6},{7}) work_tl=({8},{9}) {10}x{11} dpi={12}{13}" -f `
      $d.Index, $ptW, $ptH, $d.Width, $d.Height, (Format-Num $d.Scale), $d.Left, $d.Top, $d.WorkLeft, $d.WorkTop, `
      ($d.WorkRight - $d.WorkLeft), ($d.WorkBottom - $d.WorkTop), $d.Dpi, $flags)
  }
  return 0
}

function Invoke-ShotCommand {
  param([string[]]$Rest)
  $display = $null; $rect = $null; $cursor = $false; $toClip = $false; $outPath = $null
  $grid = $null; $zoom = $null
  $i = 0
  while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    switch ($a) {
      '-D' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage 'shot -D N' }
        $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage 'shot -D N' }
        $display = $n; $i += 2; continue
      }
      '-R' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage '-R 需要 X,Y,W,H' }
        $o = ConvertFrom-RectString $Rest[$i + 1]
        if ($null -eq $o) { Fail-Usage '-R 需要 X,Y,W,H' }
        $rect = $o; $i += 2; continue
      }
      '-o' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage 'shot -o PATH' }
        $outPath = $Rest[$i + 1]; $i += 2; continue
      }
      '-C' { $cursor = $true; $i++; continue }
      '-c' { $toClip = $true; $i++; continue }
      '--grid' {
        $grid = 50.0
        if ($i + 1 -lt $Rest.Count) {
          $v = 0.0
          if ([double]::TryParse($Rest[$i + 1], [ref]$v) -and $v -gt 0) { $grid = $v; $i++ }
        }
        $i++; continue
      }
      '--zoom' {
        $zoom = 2.0
        if ($i + 1 -lt $Rest.Count) {
          $v = 0.0
          if ([double]::TryParse($Rest[$i + 1], [ref]$v) -and $v -gt 1) { $zoom = $v; $i++ }
        }
        $i++; continue
      }
      default { Fail-Usage ("未知选项: " + $a) }
    }
  }
  $disp = $null
  if ($null -ne $display) {
    $disp = Get-Display -Index $display
    if ($null -eq $disp) {
      $avail = (Get-DisplayList | ForEach-Object { $_.Index }) -join ', '
      Write-ErrLine ("没有第 {0} 块屏；可用: [{1}]" -f $display, $avail)
      return 2
    }
  }

  if ($script:Dry) {
    $s = 'dry: would shot'
    if ($null -ne $display) { $s += " -D $display" }
    if ($rect) { $s += (" -R {0},{1},{2},{3}" -f [int]$rect.X, [int]$rect.Y, [int]$rect.W, [int]$rect.H) }
    if ($cursor) { $s += ' -C' }
    if ($toClip) { $s += ' -c' }
    if ($outPath) { $s += " -o $outPath" }
    if ($null -ne $grid) { $s += (" --grid {0}" -f (Format-Num $grid)) }
    if ($null -ne $zoom -and $zoom -gt 1) { $s += (" --zoom {0}" -f (Format-Num $zoom)) }
    Write-Out $s
    return 0
  }

  # 采集区域的几何 + 映射基准
  if ($rect) {
    $cx = [int]$rect.X; $cy = [int]$rect.Y; $cw = [int]$rect.W; $ch = [int]$rect.H
    $base = Get-DisplayForRect -X $cx -Y $cy -W $cw -H $ch
    if ($base) { $scale = $base.Scale; $label = "rect on display #$($base.Index)" }
    else { $scale = 1.0; $label = 'rect (未匹配到屏幕)' }
    $originX = $cx; $originY = $cy
    $ptW = $cw; $ptH = $ch
  } else {
    if ($null -eq $disp) { $disp = Get-Display -Index 1 }
    if ($null -eq $disp) { $disp = (Get-DisplayList)[0] }
    $cx = $disp.Left; $cy = $disp.Top; $cw = $disp.Width; $ch = $disp.Height
    $scale = $disp.Scale
    $label = "display #$($disp.Index)"
    if ($disp.Index -eq 1) { $label += ' (main)' }
    $originX = $disp.Left; $originY = $disp.Top
    $ptW = ConvertTo-Pt $cw $scale; $ptH = ConvertTo-Pt $ch $scale
  }

  $path = Get-ShotPath -OutPath $outPath
  if ($toClip) {
    # mac 的 -c：直接进剪贴板；-C/-o/--grid/--zoom 被忽略
    $bmp = $null
    try { $bmp = New-Capture -X $cx -Y $cy -W $cw -H $ch -WithCursor:$false } catch { Write-ErrLine '截图失败'; return 1 }
    try {
      $tmp = [System.IO.Path]::Combine($env:TEMP, ("dsh-ui-clip-{0}.png" -f (Get-Random)))
      [DshImg]::Save($bmp, $tmp)
      Set-ClipboardImageFile -Path $tmp
      Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
      Write-Out 'ok clipboard'
    } catch {
      $bmp.Dispose()
      Write-ErrLine ("截图失败 — 写入剪贴板出错：" + $_.Exception.Message)
      return 1
    }
    $bmp.Dispose()
    return 0
  }

  try {
    $bmp = New-Capture -X $cx -Y $cy -W $cw -H $ch -WithCursor:$cursor
  } catch {
    Write-ErrLine ('截图失败 — ' + $_.Exception.Message)
    return 1
  }
  try {
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    [DshImg]::Save($bmp, $path)
  } catch {
    $bmp.Dispose()
    Write-ErrLine ('截图失败 — ' + $_.Exception.Message)
    return 1
  }
  $bmp.Dispose()

  $final = $path
  # Windows 上截图就是 1:1 物理像素，所以「每全局像素对应几个图像像素」= 放大倍数（无放大时 1）
  $effScale = 1.0
  if ($null -ne $zoom -and $zoom -gt 1) {
    try {
      $z = Add-ZoomOverlay -Path $final -Factor $zoom
      if ($z) { $final = $z; $effScale = $zoom }
    } catch { Write-Out '  警告: 放大失败，已保留原图' }
  }
  if ($null -ne $grid) {
    try {
      $g = Add-GridOverlay -Path $final -StepPt $grid -Scale $scale -OriginX $originX -OriginY $originY -Zoom $effScale
      if ($g) { $final = $g }
    } catch { Write-Out '  警告: 网格绘制失败，已保留未叠加图' }
  }

  $head = "ok path=$final $label px=${cw}x${ch} pt=${ptW}x${ptH} scale=$(Format-Num $scale) origin=($originX,$originY)"
  if ($null -ne $zoom -and $zoom -gt 1) { $head += " zoom=$(Format-Num $zoom)x" }
  if ($null -ne $grid) { $head += " grid=$(Format-Num $grid)pt" }
  Write-Out $head
  if ($effScale -eq 1) {
    Write-Out ("   mapping: global_x = {0} + px_x   global_y = {1} + px_y   (1:1 物理像素)" -f $originX, $originY)
  } else {
    Write-Out ("   mapping: global_x = {0} + px_x/{1}   global_y = {2} + px_y/{3}   (图被放大 {1}x)" -f `
      $originX, (Format-Num $effScale), $originY, (Format-Num $effScale))
  }
  if ($final -ne $path) { Write-Out "   原图: $path" }
  if ($null -ne $grid) { Write-Out '   网格已把**全局左上坐标**写在图上：红线标 x，蓝线标 y，粗线是 5 格整数倍' }
  return 0
}

# -R 的解析：必须是逗号分隔的 4 个数，空格不算分隔符（与 macOS 版一致）
function ConvertFrom-RectString {
  param([string]$S)
  if (-not $S) { return $null }
  $parts = $S.Split(',')
  if ($parts.Count -ne 4) { return $null }
  $vals = @()
  foreach ($p in $parts) {
    $v = 0.0
    if (-not [double]::TryParse($p, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $null }
    $vals += $v
  }
  return [pscustomobject]@{ X = $vals[0]; Y = $vals[1]; W = $vals[2]; H = $vals[3] }
}

function ConvertFrom-Int {
  param([string]$S, [ref]$Out)
  return [int]::TryParse($S, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, $Out)
}

function Invoke-DiffCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 2) { Fail-Usage 'diff A.png B.png [--threshold 12] [-D N] [-R X,Y,W,H]' }
  $pa = Expand-Path $Rest[0]; $pb = Expand-Path $Rest[1]
  $threshold = 12; $display = $null; $rect = $null
  $i = 2
  while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    switch ($a) {
      '--threshold' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage '--threshold N' }
        $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '--threshold N' }
        $threshold = $n; $i += 2; continue
      }
      '-D' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage '-D N' }
        $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '-D N' }
        $display = $n; $i += 2; continue
      }
      '-R' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage '-R X,Y,W,H' }
        $o = ConvertFrom-RectString $Rest[$i + 1]
        if ($null -eq $o) { Fail-Usage '-R X,Y,W,H' }
        $rect = $o; $i += 2; continue
      }
      default { Fail-Usage ("未知选项: " + $a) }
    }
  }
  Initialize-Image
  if (-not (Test-Path -LiteralPath $pa) -or -not (Test-Path -LiteralPath $pb)) {
    Write-ErrLine '无法读取图片'; return 1
  }
  $A = $null; $B = $null
  try {
    $A = [DshImg]::Load($pa); $B = [DshImg]::Load($pb)
    if (-not [DshImg]::SameSize($A, $B)) {
      Write-ErrLine ("尺寸不同: {0}x{1} vs {2}x{3}" -f $A.Width, $A.Height, $B.Width, $B.Height)
      return 1
    }
    # 映射基准
    if ($rect) {
      $scale = 1.0
      $d = Get-DisplayForRect -X ([int]$rect.X) -Y ([int]$rect.Y) -W ([int]$rect.W) -H ([int]$rect.H)
      if ($d) { $scale = $d.Scale } else { $scaleKnown = $false; Write-Out ("警告: -R 原点 ({0},{1}) 不在任何屏幕内，scale 按 1 处理" -f [int]$rect.X, [int]$rect.Y) }
      $originX = [int]$rect.X; $originY = [int]$rect.Y
      $x0 = [math]::Max(0, [int]($rect.X - $originX))
      $y0 = [math]::Max(0, [int]($rect.Y - $originY))
      $x1 = [math]::Min($A.Width, [int]($rect.X + $rect.W - $originX))
      $y1 = [math]::Min($A.Height, [int]($rect.Y + $rect.H - $originY))
      if (-not ($x1 -gt $x0 -and $y1 -gt $y0)) {
        Write-ErrLine ("-R 区域不在图片范围内（图 {0}x{1}px，映射 origin=({2},{3}) scale={4}）" -f $A.Width, $A.Height, $originX, $originY, (Format-Num $scale))
        return 2
      }
      $scope = ("区域 {0}x{1}pt" -f [int]$rect.W, [int]$rect.H)
    } else {
      if ($null -eq $display) { $display = 1 }
      $d = Get-Display -Index $display
      if ($d) { $originX = $d.Left; $originY = $d.Top; $scale = $d.Scale }
      else { $originX = 0; $originY = 0; $scale = 1.0 }
      $x0 = 0; $y0 = 0; $x1 = $A.Width; $y1 = $A.Height
      $scope = '全图'
    }
    $r = [DshImg]::Diff($A, $B, $threshold, $x0, $y0, $x1, $y1)
    $area = [double](($x1 - $x0) * ($y1 - $y0))
    if ($r.Changed -eq 0) {
      Write-Out ("ok 无差异（阈值 {0}，{1}）" -f $threshold, $scope)
      return 0
    }
    $pct = [math]::Round(100.0 * $r.Changed / $area, 2)
    Write-Out ("ok 变化 {0} 像素 ({1}% of {2})" -f $r.Changed, $pct.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture), $scope)
    $gx1 = $originX + $r.MinX; $gy1 = $originY + $r.MinY
    $gx2 = $originX + $r.MaxX; $gy2 = $originY + $r.MaxY
    Write-Out ("   bbox_px=({0},{1})-({2},{3}) -> global=({4},{5})-({6},{7}) center=({8},{9})" -f `
      $r.MinX, $r.MinY, $r.MaxX, $r.MaxY, [int]$gx1, [int]$gy1, [int]$gx2, [int]$gy2, `
      [int](($gx1 + $gx2) / 2), [int](($gy1 + $gy2) / 2))
    return 0
  } catch {
    Write-ErrLine ('无法读取图片: ' + $_.Exception.Message); return 1
  } finally {
    if ($A) { $A.Dispose() }
    if ($B) { $B.Dispose() }
  }
}

function Expand-Path {
  param([string]$P)
  if ($P -and $P.StartsWith('~')) { return (Join-Path $HOME $P.Substring(1).TrimStart('\', '/')) }
  return $P
}

# =========================================================== 输入层 ====
# 坐标一律「全局左上物理像素」；发送前先把落点/前台窗口喂给拦截名单。

function To-Int { param($V) return [int][math]::Truncate([double]$V) }
function To-Round { param($V) return [int][math]::Round([double]$V, [System.MidpointRounding]::AwayFromZero) }

function Set-Note {
  param([string]$Text)
  $script:Note = $Text
}

function Get-HoldDefault {
  param([string]$Cmd)
  if ($Cmd -eq 'press') { return 800 }
  if ($Cmd -eq 'tap') { return 60 }
  return 30
}

# 落点下的顶层窗口（z 序命中测试，等价 macOS 版 appUnder 的语义）
function Get-WindowAtPoint {
  param([int]$X, [int]$Y)
  $h = [DshWin]::TopLevelAt($X, $Y)
  if ($h -eq [IntPtr]::Zero) { return $null }
  return (Get-WindowOwner -Hwnd $h)
}

function Assert-PointAllowed {
  param([int]$X, [int]$Y, [string]$Where)
  $h = [DshWin]::TopLevelAt($X, $Y)
  if ($h -ne [IntPtr]::Zero) { Assert-NotDenied -Where "$Where ($X,$Y)" -Hwnd $h }
}

# 点击前把落点所属窗口提到前台：Windows 下点击本来也会激活，但焦点切换是异步的，
# 紧接着投递的按键/拖拽可能落到旧的前台窗口上 —— 与 macOS 版的动机一致。
function Ensure-FrontmostForClick {
  param([int]$X, [int]$Y)
  $owner = Get-WindowAtPoint -X $X -Y $Y
  if ($null -eq $owner) { return }
  if ([DshWin]::GetForegroundWindow() -eq $owner.Hwnd) { return }
  $name = $owner.App
  [void][DshWin]::ForceForeground($owner.Hwnd)
  $deadline = (Get-Date).AddMilliseconds(500)
  while ((Get-Date) -lt $deadline) {
    if ([DshWin]::GetForegroundWindow() -eq $owner.Hwnd) { break }
    Start-Sleep -Milliseconds 25
  }
  if ([DshWin]::GetForegroundWindow() -eq $owner.Hwnd) {
    $t = "提示: 目标 App「$name」先前不在前台，已先激活再点击"
  } else {
    $t = "警告: 目标 App「$name」未能成为前台（可能被其他窗口抢占），本次点击可能只用于激活窗口"
  }
  Write-Out ("  " + $t)
  Set-Note $t
}

# 拖拽起手点贴窗口边缘时告警：Windows 上贴边拖拽会把窗口拖走/缩放
function Get-EdgeWarning {
  param([int]$X, [int]$Y, [double]$Margin)
  if ($Margin -le 0) { return $null }
  $owner = Get-WindowAtPoint -X $X -Y $Y
  if ($null -eq $owner) { return $null }
  $r = $owner.Rect
  $minX = $r[0]; $minY = $r[1]; $maxX = $r[0] + $r[2]; $maxY = $r[1] + $r[3]
  if ($X -lt $minX -or $X -gt $maxX -or $Y -lt $minY -or $Y -gt $maxY) { return $null }
  $d = [math]::Min([math]::Min($X - $minX, $maxX - $X), [math]::Min($Y - $minY, $maxY - $Y))
  if ($d -lt $Margin) {
    return ("起手点距窗口「{0}」边缘仅 {1}px（阈值 {2}px）：该拖拽可能被 Windows 当成窗口移动/缩放，而不是内容拖拽；建议起点内移，或显式加 --edge-guard 0" -f $owner.App, (To-Int $d), (To-Int $Margin))
  }
  return $null
}

function Get-CursorLine {
  Start-Sleep -Milliseconds 25
  $c = Get-CursorPoint
  return ("ok cursor=({0},{1}) top-left-coords" -f $c[0], $c[1])
}

function Invoke-PosCommand {
  Write-Out (Get-CursorLine)
  return 0
}

function Invoke-MoveCommand {
  param([string[]]$Rest)
  $p = ConvertFrom-PointArgs -Rest $Rest -Usage 'move X Y'
  if ($script:Dry) { Write-Out ("dry: would move ({0},{1})" -f $p[0], $p[1]); return 0 }
  Assert-PointAllowed -X $p[0] -Y $p[1] -Where 'move'
  [DshWin]::MouseMove($p[0], $p[1])
  Write-Out (Get-CursorLine)
  return 0
}

function ConvertFrom-PointArgs {
  param([string[]]$Rest, [string]$Usage)
  if ($Rest.Count -lt 2) { Fail-Usage $Usage }
  $x = 0; $y = 0
  if (-not [int]::TryParse($Rest[0], [ref]$x) -or -not [int]::TryParse($Rest[1], [ref]$y)) {
    Fail-Usage ("坐标必须是整数：" + ($Rest -join ' '))
  }
  return @($x, $y)
}

function Invoke-ClickCommand {
  param([string]$Cmd, [string[]]$Rest)
  if ($Rest.Count -lt 2) {
    $u = "用法: $Cmd X Y"
    if ($Cmd -in @('click', 'tap', 'press')) { $u += ' [MS]' }
    Fail-Usage $u
  }
  $x = 0; $y = 0
  if (-not [int]::TryParse($Rest[0], [ref]$x) -or -not [int]::TryParse($Rest[1], [ref]$y)) {
    Fail-Usage ("坐标必须是整数：" + ($Rest -join ' '))
  }
  $hold = Get-HoldDefault -Cmd $Cmd
  $autoActivate = $true
  $i = 2
  while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    if ($a -eq '--no-activate') { $autoActivate = $false; $i++; continue }
    $n = 0
    if ([int]::TryParse($a, [ref]$n)) { $hold = $n; $i++; continue }
    Fail-Usage ("未知选项: " + $a)
  }
  if ($script:Dry) {
    $s = "dry: would $Cmd ($x,$y) hold=${hold}ms"
    if (-not $autoActivate) { $s += ' no-activate' }
    Write-Out $s
    return 0
  }
  Assert-PointAllowed -X $x -Y $y -Where $Cmd
  if ($autoActivate -and $Cmd -ne 'rclick') { Ensure-FrontmostForClick -X $x -Y $y }
  [DshWin]::MouseMove($x, $y)
  switch ($Cmd) {
    'rclick' {
      [DshWin]::MouseDown('right'); Start-Sleep -Milliseconds ([math]::Max(1, $hold)); [DshWin]::MouseUp('right')
    }
    'dclick' {
      foreach ($k in 1..2) {
        Start-Sleep -Milliseconds 30
        [DshWin]::MouseDown('left'); Start-Sleep -Milliseconds 30; [DshWin]::MouseUp('left')
        if ($k -eq 1) { Start-Sleep -Milliseconds 60 }
      }
    }
    default {
      Start-Sleep -Milliseconds 30
      [DshWin]::MouseDown('left'); Start-Sleep -Milliseconds ([math]::Max(1, $hold)); [DshWin]::MouseUp('left')
    }
  }
  Write-Out (Get-CursorLine)
  return 0
}

function Invoke-DragCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 4) {
    Fail-Usage 'drag X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N] [--momentum F] [--edge-guard N]'
  }
  $sx = 0; $sy = 0; $ex = 0; $ey = 0
  if (-not [int]::TryParse($Rest[0], [ref]$sx) -or -not [int]::TryParse($Rest[1], [ref]$sy) -or
      -not [int]::TryParse($Rest[2], [ref]$ex) -or -not [int]::TryParse($Rest[3], [ref]$ey)) {
    Fail-Usage ("坐标必须是整数：" + ($Rest[0..3] -join ' '))
  }
  $moveMS = 216.0; $steps = 12; $holdMS = 80; $settleMS = 80; $momentum = 0.0; $edgeGuard = 12.0
  $i = 4
  while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    if ($i + 1 -ge $Rest.Count) { Fail-Usage ("$a 需要一个数值") }
    $v = 0.0
    if (-not [double]::TryParse($Rest[$i + 1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
      Fail-Usage ("$a 需要一个数值")
    }
    switch ($a) {
      '--ms' { $moveMS = $v }
      '--steps' { $steps = [int]$v }
      '--hold' { $holdMS = [int]$v }
      '--settle' { $settleMS = [int]$v }
      '--momentum' { $momentum = $v }
      '--edge-guard' { $edgeGuard = $v }
      default { Fail-Usage ("未知选项: " + $a) }
    }
    $i += 2
  }
  # 边缘告警是只读查询，干跑也要报（与 macOS 版一致）
  $warn = Get-EdgeWarning -X $sx -Y $sy -Margin $edgeGuard
  if ($warn) { Write-Out ("  警告: " + $warn); Set-Note $warn }
  if ($script:Dry) {
    Write-Out ("dry: would drag ({0},{1}) -> ({2},{3}) settle={4} hold={5} move={6} steps={7} momentum={8}" -f `
      $sx, $sy, $ex, $ey, $settleMS, $holdMS, (Format-Num $moveMS), $steps, (Format-Num $momentum))
    return 0
  }
  Assert-PointAllowed -X $sx -Y $sy -Where 'drag'
  [DshWin]::MouseMove($sx, $sy)
  Start-Sleep -Milliseconds ([math]::Max(0, $settleMS))
  [DshWin]::MouseDown('left')
  Start-Sleep -Milliseconds ([math]::Max(0, $holdMS))
  $n = [math]::Max(1, $steps)
  $per = [math]::Max(2, $moveMS / $n)
  for ($k = 1; $k -le $n; $k++) {
    $t = $k / [double]$n
    $mx = [int][math]::Round($sx + ($ex - $sx) * $t)
    $my = [int][math]::Round($sy + ($ey - $sy) * $t)
    [DshWin]::MouseMove($mx, $my)
    Start-Sleep -Milliseconds ([int]$per)
  }
  [DshWin]::MouseMove($ex, $ey)
  [DshWin]::MouseUp('left')
  Write-Out (Get-CursorLine)
  return 0
}

function Invoke-ScrollCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'scroll N [--drag] [--px-per-notch N]' }
  $amount = 0
  if (-not [int]::TryParse($Rest[0], [ref]$amount)) { Fail-Usage 'scroll N [--drag] [--px-per-notch N]' }
  $asDrag = $false; $pxPerNotch = 100.0
  $i = 1
  while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    if ($a -eq '--drag') { $asDrag = $true; $i++; continue }
    if ($a -eq '--px-per-notch') {
      if ($i + 1 -ge $Rest.Count) { Fail-Usage '--px-per-notch N' }
      $v = 0.0
      if (-not [double]::TryParse($Rest[$i + 1], [ref]$v) -or $v -le 0) { Fail-Usage '--px-per-notch N' }
      $pxPerNotch = $v; $i += 2; continue
    }
    Fail-Usage ("未知选项: " + $a)
  }
  if ($script:Dry) {
    $s = "dry: would scroll $amount"
    if ($asDrag) { $s += ' (as drag)' }
    Write-Out $s
    return 0
  }
  if ($asDrag) {
    $cur = Get-CursorPoint
    $disp = Get-DisplayForPoint -X $cur[0] -Y $cur[1]
    $endY = $cur[1] - $amount
    if ($disp) {
      $endY = [math]::Min([math]::Max($endY, $disp.WorkTop + 6), $disp.WorkBottom - 6)
    }
    Assert-PointAllowed -X $cur[0] -Y $cur[1] -Where 'scroll --drag'
    $warn = Get-EdgeWarning -X $cur[0] -Y $cur[1] -Margin 12
    if ($warn) { Write-Out ("  警告: " + $warn); Set-Note $warn }
    [DshWin]::MouseMove($cur[0], $cur[1])
    Start-Sleep -Milliseconds 60
    [DshWin]::MouseDown('left')
    Start-Sleep -Milliseconds 90
    $steps = 18
    for ($k = 1; $k -le $steps; $k++) {
      $t = $k / [double]$steps
      [DshWin]::MouseMove($cur[0], [int][math]::Round($cur[1] + ($endY - $cur[1]) * $t))
      Start-Sleep -Milliseconds ([int][math]::Max(2, 260 / $steps))
    }
    [DshWin]::MouseUp('left')
    Write-Out ("ok 以拖拽模拟滚动 {0}px: ({1},{2}) -> ({3},{4})" -f $amount, $cur[0], $cur[1], $cur[0], (To-Int $endY))
    return 0
  }
  # 滚轮：Windows 的 wheel 事件以 120 为单位（一行 = 120/3），这里按 px→档换算。
  # 与 macOS 的像素级手势不同，见 docs/REFERENCE-WINDOWS.md「与 macOS 版的差异」。
  $notches = [int][math]::Ceiling([math]::Abs($amount) / $pxPerNotch)
  if ($notches -lt 1) { $notches = 1 }
  $delta = -120 * [math]::Sign($amount)
  $remaining = $notches
  while ($remaining -gt 0) {
    $chunk = [math]::Min(3, $remaining)
    [DshWin]::MouseWheel([int]($delta * $chunk), $false)
    $remaining -= $chunk
    if ($remaining -gt 0) { Start-Sleep -Milliseconds 15 }
  }
  return 0
}

function Invoke-TypeCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'type TEXT' }
  $text = ($Rest -join ' ')
  if ($script:Dry) { Write-Out ("dry: would type {0} 字符" -f $text.Length); return 0 }
  $h = [DshWin]::GetForegroundWindow()
  if ($h -ne [IntPtr]::Zero) { Assert-NotDenied -Where 'type（前台窗口）' -Hwnd $h }
  [DshWin]::TypeUnicode($text)
  Start-Sleep -Milliseconds ([math]::Max(12, 6 * $text.Length))
  return 0
}

# 单字符 → 虚拟键码（VkKeyScan 按当前键盘布局解析，比硬编码表更贴近真实键盘）
function Get-KeyStroke {
  param([char]$Ch)
  $scan = [DshWin]::VkFor($Ch)
  if ($scan -eq -1) { return $null }
  $lo = $scan -band 0xFF
  $hi = ($scan -shr 8) -band 0xFF
  return [pscustomobject]@{ Vk = [int]$lo; Shift = (($hi -band 1) -ne 0); Ctrl = (($hi -band 2) -ne 0); Alt = (($hi -band 4) -ne 0) }
}

function Send-KeyStroke {
  param($Stroke)
  if ($Stroke.Ctrl) { [DshWin]::KeyVk(0x11, $true, $false) }
  if ($Stroke.Alt) { [DshWin]::KeyVk(0x12, $true, $false) }
  if ($Stroke.Shift) { [DshWin]::KeyVk(0x10, $true, $false) }
  Start-Sleep -Milliseconds 4
  [DshWin]::KeyVk([uint16]$Stroke.Vk, $true, [bool]$Stroke.Extended)
  Start-Sleep -Milliseconds 8
  [DshWin]::KeyVk([uint16]$Stroke.Vk, $false, [bool]$Stroke.Extended)
  if ($Stroke.Shift) { Start-Sleep -Milliseconds 4; [DshWin]::KeyVk(0x10, $false, $false) }
  if ($Stroke.Alt) { [DshWin]::KeyVk(0x12, $false, $false) }
  if ($Stroke.Ctrl) { [DshWin]::KeyVk(0x11, $false, $false) }
}

function Invoke-KeysCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'keys TEXT' }
  $text = ($Rest -join ' ')
  $strokes = @()
  foreach ($ch in $text.ToCharArray()) {
    $s = Get-KeyStroke -Ch $ch
    $strokes += , @{ ch = $ch; s = $s }
  }
  if ($script:Dry) {
    Write-Out ("dry: would send {0} 个键码字符:" -f $text.Length)
    $parts = @()
    foreach ($item in $strokes) {
      if ($null -eq $item.s) { $parts += ("{0}=无键码" -f $item.ch) }
      else {
        $t = "{0}=0x{1:x}" -f $item.ch, $item.s.Vk
        if ($item.s.Shift) { $t += '+shift' }
        $parts += $t
      }
    }
    Write-Out ("  " + ($parts -join ' '))
    return 0
  }
  $h = [DshWin]::GetForegroundWindow()
  if ($h -ne [IntPtr]::Zero) { Assert-NotDenied -Where 'keys（前台窗口）' -Hwnd $h }
  $sent = 0; $skipped = @()
  foreach ($item in $strokes) {
    if ($null -eq $item.s) { $skipped += $item.ch; continue }
    Send-KeyStroke -Stroke $item.s
    $sent++
    Start-Sleep -Milliseconds 12
  }
  $line = "ok keys 发送 $sent 个字符"
  if ($skipped.Count -gt 0) {
    $line += ("；跳过 {0} 个无键码字符: [{1}]" -f $skipped.Count, (($skipped | ForEach-Object { '"' + $_ + '"' }) -join ', '))
  }
  Write-Out $line
  if ($sent -gt 0) { return 0 }
  return 1
}

# 命名键（Windows 虚拟键码）
$script:KeyMap = @{
  'return' = 0x0D; 'enter' = 0x0D; 'tab' = 0x09; 'space' = 0x20; 'esc' = 0x1B; 'escape' = 0x1B
  'backspace' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D; 'ins' = 0x2D
  'left' = 0x25; 'up' = 0x26; 'right' = 0x27; 'down' = 0x28
  'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22; 'prior' = 0x21; 'next' = 0x22
  'capslock' = 0x14; 'numlock' = 0x90; 'scrolllock' = 0x91; 'printscreen' = 0x2C; 'prtsc' = 0x2C
  'pause' = 0x13; 'apps' = 0x5D; 'menu' = 0x5D
  'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74; 'f6' = 0x75
  'f7' = 0x76; 'f8' = 0x77; 'f9' = 0x78; 'f10' = 0x79; 'f11' = 0x7A; 'f12' = 0x7B
  'f13' = 0x7C; 'f14' = 0x7D; 'f15' = 0x7E; 'f16' = 0x7F; 'f17' = 0x80; 'f18' = 0x81
  'f19' = 0x82; 'f20' = 0x83; 'f21' = 0x84; 'f22' = 0x85; 'f23' = 0x86; 'f24' = 0x87
  'numpad0' = 0x60; 'numpad1' = 0x61; 'numpad2' = 0x62; 'numpad3' = 0x63; 'numpad4' = 0x64
  'numpad5' = 0x65; 'numpad6' = 0x66; 'numpad7' = 0x67; 'numpad8' = 0x68; 'numpad9' = 0x69
  'multiply' = 0x6A; 'add' = 0x6B; 'subtract' = 0x6D; 'decimal' = 0x6E; 'divide' = 0x6F
}
$script:ExtendedKeys = @(0x25, 0x26, 0x27, 0x28, 0x21, 0x22, 0x23, 0x24, 0x2D, 0x2E, 0x2C, 0x5D, 0x6F,
  0xA3, 0xA5, 0x5B, 0x5C, 0x90)
$script:ModifierMap = @{
  'ctrl' = 0x11; 'control' = 0x11; 'cmd' = 0x11; 'command' = 0x11; 'super' = 0x5B; 'meta' = 0x5B
  'shift' = 0x10; 'alt' = 0x12; 'option' = 0x12; 'win' = 0x5B; 'windows' = 0x5B
}

function Invoke-KeyCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'key KEY（如 key ctrl+shift+s、key enter、key win+r）' }
  $spec = $Rest[0]
  $mods = @()
  $keyName = $spec
  if ($spec.Contains('+')) {
    $parts = $spec.Split('+')
    $keyName = $parts[$parts.Count - 1]
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
      $m = $parts[$i].ToLowerInvariant()
      if (-not $script:ModifierMap.ContainsKey($m)) { Fail-Usage ("未知修饰键: " + $parts[$i]) }
      $mods += $script:ModifierMap[$m]
    }
  }
  $vk = -1
  $lower = $keyName.ToLowerInvariant()
  if ($script:KeyMap.ContainsKey($lower)) { $vk = [int]$script:KeyMap[$lower] }
  elseif ($keyName.Length -eq 1) {
    $s = Get-KeyStroke -Ch $keyName[0]
    if ($s) { $vk = $s.Vk; if ($s.Shift) { $mods += 0x10 } }
  }
  if ($vk -lt 0) { Fail-Usage ("未知按键: " + $keyName) }
  if ($script:Dry) { Write-Out ("dry: would press " + $spec); return 0 }
  $h = [DshWin]::GetForegroundWindow()
  if ($h -ne [IntPtr]::Zero) { Assert-NotDenied -Where 'key（前台窗口）' -Hwnd $h }
  foreach ($m in $mods) { [DshWin]::KeyVk([uint16]$m, $true, ($script:ExtendedKeys -contains $m)) }
  Start-Sleep -Milliseconds 8
  $ext = $script:ExtendedKeys -contains $vk
  [DshWin]::KeyVk([uint16]$vk, $true, $ext)
  Start-Sleep -Milliseconds 20
  [DshWin]::KeyVk([uint16]$vk, $false, $ext)
  for ($i = $mods.Count - 1; $i -ge 0; $i--) {
    $m = $mods[$i]
    [DshWin]::KeyVk([uint16]$m, $false, ($script:ExtendedKeys -contains $m))
  }
  return 0
}

# =========================================================== 定位层 ====
function Initialize-Uia {
  if (-not $script:UiaLoaded) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $script:UiaLoaded = $true
  }
}

# 窗口归属进程：优先走原生 API；受限令牌/沙箱下它会返回无效 PID，此时回落到 UIA。
function Get-OwnerPid {
  param([IntPtr]$Hwnd)
  $native = [int][DshWin]::GetWindowThreadProcessId($Hwnd, [IntPtr]::Zero)
  if ([DshWin]::IsPidValid($native)) { return $native }
  try {
    Initialize-Uia
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    if ($el -and $el.Current.ProcessId -gt 0) { return [int]$el.Current.ProcessId }
  } catch { }
  return $native
}

function Get-WindowOwner {
  param([IntPtr]$Hwnd)
  $raw = [DshWin]::RawDescribe($Hwnd)
  $opid = Get-OwnerPid -Hwnd $Hwnd
  $names = [DshWin]::ProcessNames($opid)
  $app = $names[1]
  if (-not $app) { $app = $names[0] }
  return [pscustomobject]@{
    Hwnd    = $Hwnd
    Pid     = $opid
    Process = $names[0]
    App     = $app
    Title   = $raw.Title
    Class   = $raw.Class
    Rect    = @([int]$raw.Left, [int]$raw.Top, [int]($raw.Right - $raw.Left), [int]($raw.Bottom - $raw.Top))
    Minimized = [bool]$raw.Minimized
    Maximized = [bool]$raw.Maximized
    Foreground = [bool]$raw.Foreground
  }
}

function Get-WindowList {
  $out = @()
  $i = 0
  foreach ($raw in [DshWin]::RawWindows($true)) {
    $i++
    $opid = Get-OwnerPid -Hwnd $raw.Hwnd
    $names = [DshWin]::ProcessNames($opid)
    $app = $names[1]; if (-not $app) { $app = $names[0] }
    $mon = Get-DisplayForPoint -X ([int](($raw.Left + $raw.Right) / 2)) -Y ([int](($raw.Top + $raw.Bottom) / 2))
    $out += [pscustomobject]@{
      Index = $i; Hwnd = $raw.Hwnd; Pid = $opid; Process = $names[0]; App = $app
      Title = $raw.Title; Class = $raw.Class
      Left = [int]$raw.Left; Top = [int]$raw.Top
      Width = [int]($raw.Right - $raw.Left); Height = [int]($raw.Bottom - $raw.Top)
      CenterX = [int](($raw.Left + $raw.Right) / 2); CenterY = [int](($raw.Top + $raw.Bottom) / 2)
      Minimized = [bool]$raw.Minimized; Maximized = [bool]$raw.Maximized; Foreground = [bool]$raw.Foreground
      Monitor = $(if ($mon) { $mon.Index } else { 0 })
    }
  }
  return $out
}

function Invoke-WinCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'win list | focus N | maximize N | fullscreen N | move N X Y [W H] | close N | minimize N | restore N' }
  $sub = $Rest[0]
  $json = $false
  $rest2 = @()
  foreach ($a in $Rest) { if ($a -eq '--json') { $json = $true } else { $rest2 += $a } }
  if ($sub -eq 'list') {
    $ws = @(Get-WindowList)
    if ($json) {
      $arr = @()
      foreach ($w in $ws) {
        $arr += [ordered]@{ index = $w.Index; app = $w.App; process = $w.Process; title = $w.Title; class = $w.Class
          pid = $w.Pid; pos = @($w.Left, $w.Top); size = @($w.Width, $w.Height); center = @($w.CenterX, $w.CenterY)
          monitor = $w.Monitor; minimized = $w.Minimized; maximized = $w.Maximized; foreground = $w.Foreground }
      }
      Write-Out ((ConvertTo-Json -InputObject @{ windows = $arr } -Depth 6 -Compress))
      return 0
    }
    if ($ws.Count -eq 0) { Write-ErrLine '没有可见窗口'; return 1 }
    foreach ($w in $ws) {
      $flag = ''
      if ($w.Minimized) { $flag = ' min' } elseif ($w.Maximized) { $flag = ' max' }
      Write-Out ("[{0}] {1} — `"{2}`" pos=({3},{4}) size={5}x{6} center=({7},{8}) pid={9}{10}" -f `
        $w.Index, $w.App, $w.Title, $w.Left, $w.Top, $w.Width, $w.Height, $w.CenterX, $w.CenterY, $w.Pid, $flag)
    }
    return 0
  }
  if ($rest2.Count -lt 2) { Fail-Usage '需要窗口序号' }
  $idx = 0
  if (-not [int]::TryParse($rest2[1], [ref]$idx)) { Fail-Usage '需要窗口序号' }
  $ws = @(Get-WindowList)
  $w = $null
  foreach ($cand in $ws) { if ($cand.Index -eq $idx) { $w = $cand; break } }
  if ($null -eq $w) { Write-ErrLine ("没有序号为 {0} 的窗口" -f $idx); return 1 }

  if ($script:Dry) {
    Write-Out ("dry: would {0} window [{1}] {2}" -f $sub, $idx, $w.App)
    return 0
  }

  switch ($sub) {
    'focus' {
      [void][DshWin]::ForceForeground($w.Hwnd)
      $deadline = (Get-Date).AddMilliseconds(700)
      while ((Get-Date) -lt $deadline) {
        if ([DshWin]::GetForegroundWindow() -eq $w.Hwnd) { break }
        Start-Sleep -Milliseconds 25
      }
      $front = ([DshWin]::GetForegroundWindow() -eq $w.Hwnd)
      $line = "ok focused [$idx] $($w.App)"
      if (-not $front) { $line += '（警告：未能确认成为前台窗口 — 下一击可能只用于激活窗口，必要时点两次）' }
      Write-Out $line
      return 0
    }
    'maximize' {
      if ($w.Minimized) { [void][DshWin]::ShowWindow($w.Hwnd, 9) ; Start-Sleep -Milliseconds 150 }
      $mon = Get-DisplayForPoint -X $w.CenterX -Y $w.CenterY
      if ($null -eq $mon) { $mon = Get-Display -Index 1 }
      $tw = $mon.WorkRight - $mon.WorkLeft; $th = $mon.WorkBottom - $mon.WorkTop
      [void][DshWin]::ShowWindow($w.Hwnd, 3)   # SW_MAXIMIZE：Windows 自己会精确填满工作区
      Start-Sleep -Milliseconds 200
      [void][DshWin]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $mon.WorkLeft, $mon.WorkTop, $tw, $th, 0x14)
      Start-Sleep -Milliseconds 150
      $now = [DshWin]::RawDescribe($w.Hwnd)
      $line = ("ok maximized [{0}] -> pos=({1},{2}) size={3}x{4}" -f $idx, $now.Left, $now.Top, ($now.Right - $now.Left), ($now.Bottom - $now.Top))
      if (($now.Right - $now.Left) -lt $tw - 2 -or ($now.Bottom - $now.Top) -lt $th - 2) {
        $line += ("（小于工作区 {0}x{1}，该窗口可能自限尺寸）" -f $tw, $th)
      }
      Write-Out $line
      return 0
    }
    'fullscreen' {
      # Windows 没有「按窗口切换原生全屏」的通用开关：这里用「填满整块显示器」近似
      $mon = Get-DisplayForPoint -X $w.CenterX -Y $w.CenterY
      if ($null -eq $mon) { $mon = Get-Display -Index 1 }
      $fw = $mon.Right - $mon.Left; $fh = $mon.Bottom - $mon.Top
      $now = [DshWin]::RawDescribe($w.Hwnd)
      $on = -not (($now.Left -le $mon.Left) -and ($now.Top -le $mon.Top) -and (($now.Right - $now.Left) -ge $fw) -and (($now.Bottom - $now.Top) -ge $fh))
      if ($on) {
        [void][DshWin]::ShowWindow($w.Hwnd, 9)
        Start-Sleep -Milliseconds 150
        [void][DshWin]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $mon.Left, $mon.Top, $fw, $fh, 0x14)
        Write-Out ("ok fullscreen fill [{0}]（Windows：填充整块屏幕，不是 macOS 的原生全屏空间）" -f $idx)
      } else {
        $tw = $mon.WorkRight - $mon.WorkLeft; $th = $mon.WorkBottom - $mon.WorkTop
        [void][DshWin]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $mon.WorkLeft, $mon.WorkTop, $tw, $th, 0x14)
        Write-Out ("ok fullscreen off [{0}]（已还原到工作区）" -f $idx)
      }
      return 0
    }
    'move' {
      if ($rest2.Count -lt 4) { Fail-Usage 'win move N X Y [W H]' }
      $x = 0; $y = 0
      if (-not [int]::TryParse($rest2[2], [ref]$x) -or -not [int]::TryParse($rest2[3], [ref]$y)) { Fail-Usage 'win move N X Y [W H]' }
      $ww = $w.Width; $hh = $w.Height
      if ($rest2.Count -ge 6) {
        $a = 0; $b = 0
        if ([int]::TryParse($rest2[4], [ref]$a) -and [int]::TryParse($rest2[5], [ref]$b)) { $ww = $a; $hh = $b }
      }
      [void][DshWin]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $x, $y, $ww, $hh, 0x14)
      Write-Out ("ok moved [{0}] to ({1},{2})" -f $idx, $x, $y)
      return 0
    }
    'close' {
      [void][DshWin]::PostMessage($w.Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
      Write-Out ("ok closed [{0}] $($w.App)" -f $idx)
      return 0
    }
    'minimize' {
      [void][DshWin]::ShowWindow($w.Hwnd, 6)
      Write-Out ("ok minimized [{0}] $($w.App)" -f $idx)
      return 0
    }
    'restore' {
      [void][DshWin]::ShowWindow($w.Hwnd, 9)
      Write-Out ("ok restored [{0}] $($w.App)" -f $idx)
      return 0
    }
    default { Fail-Usage ("未知子命令: " + $sub) }
  }
  return 0
}

function Invoke-UnderCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 2) { Fail-Usage 'under X Y' }
  $x = 0; $y = 0
  if (-not [int]::TryParse($Rest[0], [ref]$x) -or -not [int]::TryParse($Rest[1], [ref]$y)) { Fail-Usage 'under X Y' }
  $owner = Get-WindowAtPoint -X $x -Y $y
  if ($null -eq $owner) {
    Write-ErrLine ("({0},{1}) 处没有窗口元素" -f $x, $y)
    return 1
  }
  $line = ("ok ({0},{1}) -> {2} [{3}]" -f $x, $y, $owner.App, $owner.Process)
  $detail = $null
  try {
    Initialize-Uia
    $pt = New-Object System.Windows.Point($x, $y)
    $el = [System.Windows.Automation.AutomationElement]::FromPoint($pt)
    if ($el) {
      $ct = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
      $nm = $el.Current.Name
      $detail = ("   element: {0} `"{1}`"" -f $ct, $nm)
    }
  } catch { }
  Write-Out $line
  if ($detail) { Write-Out $detail }
  $hit = Test-Denied -ProcessName $owner.Process -AppName $owner.App -Title $owner.Title
  if ($hit) { Write-Out ("   该 App 在拦截名单中（$hit），点击会被拒绝") }
  return 0
}

# ------------------------------------------------------------ find-ax ----
function Get-UiaWindowsForPid {
  param([int]$OwnerPid)
  Initialize-Uia
  $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $OwnerPid)
  $wins = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
  $out = @()
  foreach ($w in $wins) { $out += $w }
  return $out
}

function Get-UiaElementInfo {
  param($El)
  $c = $El.Current
  $rect = $c.BoundingRectangle
  $role = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
  $pressable = $false
  try {
    $p = $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($p) { $pressable = $true }
  } catch { }
  if (-not $pressable) {
    try {
      $p = $El.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
      if ($p) { $pressable = $true }
    } catch { }
  }
  $value = ''
  try {
    $vp = $El.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($vp) { $value = [string]$vp.Current.Value }
  } catch { }
  return [pscustomobject]@{
    Role = $role; Name = [string]$c.Name; AutomationId = [string]$c.AutomationId; Class = [string]$c.ClassName
    Value = $value; Enabled = [bool]$c.IsEnabled; Focusable = [bool]$c.IsKeyboardFocusable
    Pressable = $pressable
    X = [int]$rect.X; Y = [int]$rect.Y; W = [int]$rect.Width; H = [int]$rect.Height
    CenterX = [int]($rect.X + $rect.Width / 2); CenterY = [int]($rect.Y + $rect.Height / 2)
  }
}

function Invoke-FindAxCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'find-ax "文字" [--app 名称] [--pid N] [--all] [--json] [--max N] [--click]' }
  $needle = $Rest[0]
  $appFilter = $null; $pidFilter = $null; $all = $false; $json = $false; $maxHits = 20; $click = $false
  $i = 1
  while ($i -lt $Rest.Count) {
    switch ($Rest[$i]) {
      '--app' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--app 需要一个值' }; $appFilter = $Rest[$i + 1].ToLowerInvariant(); $i += 2; continue }
      '--pid' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--pid 需要一个值' }; $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '--pid 需要一个值' }; $pidFilter = $n; $i += 2; continue }
      '--max' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--max 需要一个值' }; $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '--max 需要一个值' }; $maxHits = $n; $i += 2; continue }
      '--all' { $all = $true; $i++; continue }
      '--json' { $json = $true; $i++; continue }
      '--click' { $click = $true; $i++; continue }
      default { Fail-Usage ("未知选项: " + $Rest[$i]) }
    }
  }
  Initialize-Uia

  # 目标进程集合
  $targets = @()
  if ($null -ne $pidFilter) {
    $names = [DshWin]::ProcessNames($pidFilter)
    $app = $names[1]; if (-not $app) { $app = $names[0] }
    $targets += [pscustomobject]@{ Pid = $pidFilter; App = $app; Process = $names[0] }
  } else {
    # Windows 上没有「App 名」这回事：exe 名 / 文件说明 / 窗口标题三者取并集。
    # 窗口标题最贴近用户的叫法（--app "DSH UI Target"），所以单独也当一路匹配。
    $titlePids = @{}
    if ($appFilter) {
      foreach ($raw in [DshWin]::RawWindows($true)) {
        if ($raw.Title -and $raw.Title.ToLowerInvariant().Contains($appFilter)) {
          $op = Get-OwnerPid -Hwnd $raw.Hwnd
          if ($op -gt 0) { $titlePids[[int]$op] = $true }
        }
      }
    }
    $seen = @{}
    foreach ($p in (Get-Process)) {
      $names = [DshWin]::ProcessNames($p.Id)
      $app = $names[1]; if (-not $app) { $app = $names[0] }
      $hay = ("$($names[0]) $app").ToLowerInvariant()
      $byTitle = $titlePids.ContainsKey([int]$p.Id)
      if ($appFilter) {
        if (-not ($hay.Contains($appFilter) -or $byTitle)) { continue }
      } else {
        if (-not $names[0]) { continue }
      }
      if ($seen.ContainsKey($p.Id)) { continue }
      $seen[$p.Id] = $true
      $targets += [pscustomobject]@{ Pid = $p.Id; App = $app; Process = $names[0] }
    }
    foreach ($tp in $titlePids.Keys) {
      if ($seen.ContainsKey([int]$tp)) { continue }
      $names = [DshWin]::ProcessNames([int]$tp)
      $app = $names[1]; if (-not $app) { $app = $names[0] }
      $seen[[int]$tp] = $true
      $targets += [pscustomobject]@{ Pid = [int]$tp; App = $app; Process = $names[0] }
    }
  }
  if ($targets.Count -eq 0) {
    if ($appFilter) { Write-ErrLine ("没有名称匹配「{0}」的进程" -f $appFilter); return 1 }
    Write-ErrLine '没有可扫描的进程'; return 1
  }

  $needleLower = $needle.ToLowerInvariant()
  $hits = @()
  $scanned = 0
  foreach ($t in $targets) {
    if ($hits.Count -ge $maxHits) { break }
    $wins = @()
    try { $wins = @(Get-UiaWindowsForPid -OwnerPid $t.Pid) } catch { }
    if ($wins.Count -eq 0) { continue }
    $scanned++
    foreach ($win in $wins) {
      if ($hits.Count -ge $maxHits) { break }
      $els = $null
      try { $els = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) } catch { continue }
      foreach ($el in $els) {
        if ($hits.Count -ge $maxHits) { break }
        try {
          $info = Get-UiaElementInfo -El $el
          if ($info.W -le 0 -or $info.H -le 0) { continue }
          $text = ($info.Name + " " + $info.AutomationId + " " + $info.Value).ToLowerInvariant()
          if ($text.Contains($needleLower)) {
            $info | Add-Member -NotePropertyName App -NotePropertyValue $t.App -Force
            $info | Add-Member -NotePropertyName Pid -NotePropertyValue $t.Pid -Force
            $hits += $info
          }
        } catch { }
      }
    }
  }

  if ($json) {
    $arr = @()
    foreach ($h in $hits) {
      $arr += [ordered]@{ role = $h.Role; name = $h.Name; id = $h.AutomationId; class = $h.Class; value = $h.Value
        app = $h.App; pid = $h.Pid; pos = @($h.X, $h.Y); size = @($h.W, $h.H); center = @($h.CenterX, $h.CenterY)
        pressable = $h.Pressable; enabled = $h.Enabled }
    }
    Write-Out ((ConvertTo-Json -InputObject @{ ok = ($hits.Count -gt 0); needle = $needle; matches = $arr; hit_limit = $maxHits } -Depth 6 -Compress))
    if ($hits.Count -eq 0) { return 1 }
    return 0
  }
  if ($hits.Count -eq 0) {
    Write-ErrLine ("AX 树中未找到「{0}」（已扫描 {1} 个进程）" -f $needle, $scanned)
    return 1
  }
  Write-Out ("ok AX 匹配 {0} 处" -f $hits.Count)
  $shown = $hits
  if (-not $all) { $shown = @($hits[0]) }
  $n = 0
  foreach ($h in $shown) {
    Write-Out ("  [{0}] {1} title=`"{2}`" app={3} pos=({4},{5}) size={6}x{7} pressable={8} -> dsh-ui click {9} {10}" -f `
      $n, $h.Role, $h.Name, $h.App, $h.X, $h.Y, $h.W, $h.H, $h.Pressable.ToString().ToLowerInvariant(), $h.CenterX, $h.CenterY)
    $n++
  }
  if ($click) {
    if ($script:Dry) { Write-Out ("dry: would click {0} {1}" -f $hits[0].CenterX, $hits[0].CenterY) ; return 0 }
    Assert-PointAllowed -X $hits[0].CenterX -Y $hits[0].CenterY -Where 'find-ax --click'
    Ensure-FrontmostForClick -X $hits[0].CenterX -Y $hits[0].CenterY
    [DshWin]::MouseMove($hits[0].CenterX, $hits[0].CenterY)
    Start-Sleep -Milliseconds 60
    [DshWin]::MouseDown('left'); Start-Sleep -Milliseconds 30; [DshWin]::MouseUp('left')
    Write-Out ("  已点击 ({0},{1})" -f $hits[0].CenterX, $hits[0].CenterY)
  }
  return 0
}

# -------------------------------------------------------------- OCR ----
# Windows 的 OCR 引擎（Windows.Media.Ocr）只有 Windows PowerShell 5.1 能直接加载：
# PowerShell 7 / .NET Core 没有内置 WinRT 投影。所以 PS7 下自动派生一个 5.1 子进程当 worker。
function Initialize-Ocr {
  if ($script:OcrMode) { return $script:OcrMode }
  $script:OcrMode = 'child'
  try {
    [void][Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
    [void][Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    [void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    [void][Windows.Storage.Streams.IRandomAccessStream, Windows.Storage, ContentType = WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $script:OcrAwait = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    if ($null -eq $script:OcrAwait) { $script:OcrMode = 'child' } else { $script:OcrMode = 'inproc' }
  } catch { $script:OcrMode = 'child' }
  return $script:OcrMode
}

function Wait-WinRt {
  param($Op, $Type)
  $m = $script:OcrAwait.MakeGenericMethod($Type)
  $t = $m.Invoke($null, @($Op))
  [void]$t.Wait(-1)
  return $t.Result
}

function Invoke-OcrNative {
  param([string]$Path, [string]$Lang)
  $file = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
  $stream = Wait-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  if ($Lang) {
    $langObj = New-Object Windows.Globalization.Language $Lang
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($langObj)
  } else {
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  }
  if ($null -eq $engine) { throw ("没有可用的 OCR 语言包" + $(if ($Lang) { "：$Lang" } else { '' })) }
  $res = Wait-WinRt ($engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
  $lines = @()
  foreach ($ln in $res.Lines) {
    $words = @()
    $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = 0.0; $maxY = 0.0
    foreach ($wd in $ln.Words) {
      $r = $wd.BoundingRect
      $x = [double]$r.X; $y = [double]$r.Y; $w = [double]$r.Width; $h = [double]$r.Height
      $words += [ordered]@{ t = [string]$wd.Text; x = $x; y = $y; w = $w; h = $h }
      if ($x -lt $minX) { $minX = $x }
      if ($y -lt $minY) { $minY = $y }
      if (($x + $w) -gt $maxX) { $maxX = $x + $w }
      if (($y + $h) -gt $maxY) { $maxY = $y + $h }
    }
    if ($words.Count -eq 0) { continue }
    $lines += [ordered]@{ text = [string]$ln.Text; x = $minX; y = $minY; w = ($maxX - $minX); h = ($maxY - $minY); words = $words }
  }
  return $lines
}

function Get-OcrLines {
  param([string]$Path, [string]$Lang)
  if ((Initialize-Ocr) -eq 'inproc') {
    try { return (Invoke-OcrNative -Path $Path -Lang $Lang) } catch { Write-ErrLine ('OCR 失败: ' + $_.Exception.Message); return $null }
  }
  $out = [System.IO.Path]::Combine($env:TEMP, ("dsh-ui-ocr-{0}.json" -f (Get-Random -Minimum 1000 -Maximum 999999)))
  $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $ps51)) { $ps51 = 'powershell.exe' }
  # 'auto' 表示用系统默认 OCR 语言。既不能传空字符串（原生命令行会吞掉空参数），
  # 也不能传单个 '-'（PowerShell 会把它当成空参数名并报 PSArgumentException）
  $langArg = 'auto'
  if ($Lang) { $langArg = $Lang }
  try {
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath __ocr $Path $langArg $out 2>&1 | Out-Null
    $workerExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $out)) { Write-ErrLine ('OCR 失败（worker exit=' + $workerExit + '）'); return $null }
    $json = [System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8)
    $payload = $json | ConvertFrom-Json
    if (-not $payload.ok) { Write-ErrLine ('OCR 失败: ' + $payload.error); return $null }
    return $payload.lines
  } catch {
    Write-ErrLine ('OCR 失败: ' + $_.Exception.Message); return $null
  } finally {
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-OcrWorkerMode {
  param([string]$Path, [string]$Lang, [string]$Out)
  try {
    if ((Initialize-Ocr) -ne 'inproc') { throw 'worker 宿主不支持 WinRT OCR（需要 Windows PowerShell 5.1）' }
    $lines = Invoke-OcrNative -Path $Path -Lang $Lang
    $payload = [ordered]@{ ok = $true; lines = @($lines) }
  } catch {
    $payload = [ordered]@{ ok = $false; error = $_.Exception.Message; lines = @() }
  }
  [System.IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject $payload -Depth 8 -Compress), $script:Utf8NoBom)
  return 0
}

# 把 OCR 行翻译成「匹配 needle 的文本块」。Windows OCR 会在 CJK 之间插空格，
# 所以匹配走「去掉所有空白后的大小写不敏感子串」，命中区间再回推 word 外接框。
function Find-OcrMatches {
  param($Lines, [string]$Needle)
  $matches = @()
  $compactNeedle = ($Needle -replace '\s', '').ToLowerInvariant()
  $rawNeedle = $Needle.ToLowerInvariant()
  $idx = 0
  foreach ($ln in $Lines) {
    $text = [string]$ln.text
    $compact = ''
    $spans = @()
    foreach ($wd in $ln.words) {
      $s = $compact.Length
      $compact += [string]$wd.t
      $spans += [pscustomobject]@{ S = $s; E = $compact.Length; X = [double]$wd.x; Y = [double]$wd.y; W = [double]$wd.w; H = [double]$wd.h }
    }
    $hay = $compact.ToLowerInvariant()
    $found = $false
    if ($compactNeedle.Length -gt 0) {
      $start = 0
      while ($true) {
        $pos = $hay.IndexOf($compactNeedle, $start, [System.StringComparison]::Ordinal)
        if ($pos -lt 0) { break }
        $end = $pos + $compactNeedle.Length
        $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = 0.0; $maxY = 0.0
        $any = $false
        foreach ($sp in $spans) {
          if ($sp.E -gt $pos -and $sp.S -lt $end) {
            $any = $true
            if ($sp.X -lt $minX) { $minX = $sp.X }
            if ($sp.Y -lt $minY) { $minY = $sp.Y }
            if (($sp.X + $sp.W) -gt $maxX) { $maxX = $sp.X + $sp.W }
            if (($sp.Y + $sp.H) -gt $maxY) { $maxY = $sp.Y + $sp.H }
          }
        }
        if (-not $any) { $minX = [double]$ln.x; $minY = [double]$ln.y; $maxX = $minX + [double]$ln.w; $maxY = $minY + [double]$ln.h }
        $matches += [pscustomobject]@{ Text = $text; Conf = $null
          X = $minX; Y = $minY; W = ($maxX - $minX); H = ($maxY - $minY)
          CenterX = ($minX + $maxX) / 2; CenterY = ($minY + $maxY) / 2; LineIndex = $idx }
        $found = $true
        $start = $pos + 1
      }
    }
    if (-not $found -and $rawNeedle.Length -gt 0 -and $text.ToLowerInvariant().Contains($rawNeedle)) {
      $matches += [pscustomobject]@{ Text = $text; Conf = $null
        X = [double]$ln.x; Y = [double]$ln.y; W = [double]$ln.w; H = [double]$ln.h
        CenterX = ([double]$ln.x + [double]$ln.w / 2); CenterY = ([double]$ln.y + [double]$ln.h / 2); LineIndex = $idx }
    }
    $idx++
  }
  return $matches
}

# 截图上下文：find-text / wait-for 共用。$Rect 为 $null 时截整块屏。
function New-CaptureContext {
  param($Display, $Rect)
  if ($Rect) {
    $x = [int]$Rect.X; $y = [int]$Rect.Y; $w = [int]$Rect.W; $h = [int]$Rect.H
    $base = Get-DisplayForRect -X $x -Y $y -W $w -H $h
    if ($base) { $scale = $base.Scale; $label = "rect on display #$($base.Index)" }
    else { $scale = 1.0; $label = 'rect (未匹配到屏幕)' }
    return [pscustomobject]@{ X = $x; Y = $y; W = $w; H = $h; Scale = $scale; Label = $label; OriginX = $x; OriginY = $y }
  }
  $d = $null
  if ($null -ne $Display) { $d = Get-Display -Index ([int]$Display) }
  if ($null -eq $d) { $d = Get-Display -Index 1 }
  if ($null -eq $d) { $d = (Get-DisplayList)[0] }
  $label = "display #$($d.Index)"
  if ($d.Index -eq 1) { $label += ' (main)' }
  return [pscustomobject]@{ X = $d.Left; Y = $d.Top; W = $d.Width; H = $d.Height; Scale = $d.Scale; Label = $label; OriginX = $d.Left; OriginY = $d.Top }
}

function Save-CaptureToTemp {
  param($Ctx, [switch]$WithCursor)
  Initialize-Image
  $bmp = New-Capture -X $Ctx.X -Y $Ctx.Y -W $Ctx.W -H $Ctx.H -WithCursor:$WithCursor
  $path = [System.IO.Path]::Combine($env:TEMP, ("dsh-ui-cap-{0}.png" -f (Get-Random -Minimum 1000 -Maximum 999999)))
  [DshImg]::Save($bmp, $path)
  $bmp.Dispose()
  return $path
}

function Invoke-FindTextCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'find-text "文字" [--all] [--fast] [--click] [--list] [--json] [-D N] [-R X,Y,W,H] [--lang en-US]' }
  $needle = $Rest[0]
  $all = $false; $fast = $false; $click = $false; $list = $false; $json = $false
  $display = $null; $rect = $null; $lang = $null
  $i = 1
  while ($i -lt $Rest.Count) {
    switch ($Rest[$i]) {
      '--all' { $all = $true; $i++; continue }
      '--fast' { $fast = $true; $i++; continue }
      '--click' { $click = $true; $i++; continue }
      '--list' { $list = $true; $i++; continue }
      '--json' { $json = $true; $i++; continue }
      '--lang' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--lang 需要一个值' }; $lang = $Rest[$i + 1]; $i += 2; continue }
      '-D' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage '-D N' }
        $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '-D N' }
        $display = $n; $i += 2; continue
      }
      '-R' {
        if ($i + 1 -ge $Rest.Count) { Fail-Usage '-R X,Y,W,H' }
        $o = ConvertFrom-RectString $Rest[$i + 1]
        if ($null -eq $o) { Fail-Usage '-R X,Y,W,H' }
        $rect = $o; $i += 2; continue
      }
      default { Fail-Usage ("未知选项: " + $Rest[$i]) }
    }
  }
  $ctx = New-CaptureContext -Display $display -Rect $rect
  $path = $null
  try { $path = Save-CaptureToTemp -Ctx $ctx } catch { Write-ErrLine ('截图失败 — ' + $_.Exception.Message); return 1 }
  try {
    $lines = @(Get-OcrLines -Path $path -Lang $lang)
    if ($null -eq $lines) { return 1 }
    $hits = @()
    foreach ($ln in $lines) {
      $hits += [pscustomobject]@{ Text = [string]$ln.text; Conf = $null
        X = [double]$ln.x; Y = [double]$ln.y; W = [double]$ln.w; H = [double]$ln.h
        CenterX = ([double]$ln.x + [double]$ln.w / 2); CenterY = ([double]$ln.y + [double]$ln.h / 2) }
    }
    $matches = @(Find-OcrMatches -Lines $lines -Needle $needle)
    if ($null -eq $matches) { $matches = @() }
    $clicked = $null

    if ($json) {
      $hitArr = @(); $matchArr = @()
      foreach ($h in $hits) {
        $gx = $ctx.OriginX + $h.CenterX; $gy = $ctx.OriginY + $h.CenterY
        $hitArr += [ordered]@{ conf = $null; global = @((To-Round $gx), (To-Round $gy))
          px_center = @((To-Int $h.CenterX), (To-Int $h.CenterY))
          px_rect = @((To-Int $h.X), (To-Int $h.Y), (To-Int $h.W), (To-Int $h.H)); text = $h.Text }
      }
      foreach ($m in $matches) {
        $gx = $ctx.OriginX + $m.CenterX; $gy = $ctx.OriginY + $m.CenterY
        $matchArr += [ordered]@{ conf = $null; global = @((To-Round $gx), (To-Round $gy))
          px_center = @((To-Int $m.CenterX), (To-Int $m.CenterY))
          px_rect = @((To-Int $m.X), (To-Int $m.Y), (To-Int $m.W), (To-Int $m.H)); text = $m.Text }
      }
      if ($click -and $matches.Count -gt 0) {
        $best = $matches[0]
        $gx = $ctx.OriginX + $best.CenterX; $gy = $ctx.OriginY + $best.CenterY
        if ($script:Dry) { $clicked = @((To-Int $gx), (To-Int $gy)) }
        else {
          try {
            Assert-PointAllowed -X $gx -Y $gy -Where 'find-text --click' | Out-Null
            [DshWin]::MouseMove((To-Round $gx), (To-Round $gy))
            Start-Sleep -Milliseconds 60
            [DshWin]::MouseDown('left'); Start-Sleep -Milliseconds 30; [DshWin]::MouseUp('left')
            $clicked = @((To-Int $gx), (To-Int $gy))
          } catch { $clicked = $null }   # 被拦截时静默跳过点击（与 macOS 版 --json 路径一致）
        }
      }
      $root = [ordered]@{
        capture = [ordered]@{ label = $ctx.Label; origin = @($ctx.OriginX, $ctx.OriginY); path = $path
          pt = @((ConvertTo-Pt $ctx.W $ctx.Scale), (ConvertTo-Pt $ctx.H $ctx.Scale)); px = @($ctx.W, $ctx.H); scale = $ctx.Scale }
        clicked = $clicked; hits = $hitArr; matches = $matchArr; needle = $needle; ok = ($matches.Count -gt 0)
      }
      Write-Out ((ConvertTo-Json -InputObject $root -Depth 8 -Compress))
      if ($matches.Count -eq 0) { return 1 }
      return 0
    }

    if ($list) {
      Write-Out ("ok 识别到 {0} 个文本块 ({1})" -f $hits.Count, $ctx.Label)
      $n = 0
      foreach ($h in $hits) {
        $gx = $ctx.OriginX + $h.CenterX; $gy = $ctx.OriginY + $h.CenterY
        Write-Out ("  [{0}] `"{1}`" conf=n/a -> click {2} {3}" -f $n, $h.Text, (To-Int $gx), (To-Int $gy))
        $n++
      }
      return 0
    }

    if ($matches.Count -eq 0) {
      Write-ErrLine ("未找到「{0}」— 共识别 {1} 个文本块，图 {2}x{3}px" -f $needle, $hits.Count, $ctx.W, $ctx.H)
      if ($hits.Count -gt 0) {
        Write-ErrLine ("  识别到的文字: " + (($hits | ForEach-Object { $_.Text }) -join ' / '))
      }
      Write-ErrLine '  提示: Windows OCR 对中文的字符级误识比 macOS Vision 更常见，先试更短的关键词，或用 find-ax 换通道'
      return 1
    }
    Write-Out ("ok `"{0}`" 匹配 {1} 处 ({2}, mapping: global = ({3},{4}) + px/{5})" -f `
      $needle, $matches.Count, $ctx.Label, $ctx.OriginX, $ctx.OriginY, (Format-Num $ctx.Scale))
    $shown = $matches
    if (-not $all) { $shown = @($matches[0]) }
    $n = 0
    foreach ($m in $shown) {
      $gx = $ctx.OriginX + $m.CenterX; $gy = $ctx.OriginY + $m.CenterY
      Write-Out ("  [{0}] `"{1}`" conf=n/a px_center=({2},{3}) -> dsh-ui click {4} {5}" -f `
        $n, $m.Text, (To-Int $m.CenterX), (To-Int $m.CenterY), (To-Int $gx), (To-Int $gy))
      $n++
    }
    if ($click) {
      $best = $matches[0]
      $gx = $ctx.OriginX + $best.CenterX; $gy = $ctx.OriginY + $best.CenterY
      if ($script:Dry) { Write-Out ("dry: would click {0} {1}" -f (To-Int $gx), (To-Int $gy)); return 0 }
      Assert-PointAllowed -X $gx -Y $gy -Where 'find-text --click'
      [DshWin]::MouseMove((To-Round $gx), (To-Round $gy))
      Start-Sleep -Milliseconds 60
      [DshWin]::MouseDown('left'); Start-Sleep -Milliseconds 30; [DshWin]::MouseUp('left')
      Write-Out ("  已点击 ({0},{1})" -f (To-Int $gx), (To-Int $gy))
    }
    return 0
  } finally {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }
}

# --------------------------------------------------------- wait-for ----
function Invoke-WaitForCommand {
  param([string[]]$Rest)
  $text = $null; $stable = $false; $changePath = $null
  $timeout = 20.0; $interval = 0.6; $fast = $false; $minChange = 2000; $threshold = 12
  $display = $null; $rect = $null
  $i = 0
  while ($i -lt $Rest.Count) {
    switch ($Rest[$i]) {
      '--text' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--text 需要一个值' }; $text = $Rest[$i + 1]; $i += 2; continue }
      '--change' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--change 需要一个路径' }; $changePath = Expand-Path $Rest[$i + 1]; $i += 2; continue }
      '--stable' { $stable = $true; $i++; continue }
      '--fast' { $fast = $true; $i++; continue }
      '--timeout' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--timeout N' }; $v = 0.0; if (-not [double]::TryParse($Rest[$i + 1], [ref]$v)) { Fail-Usage '--timeout N' }; $timeout = $v; $i += 2; continue }
      '--interval' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--interval N' }; $v = 0.0; if (-not [double]::TryParse($Rest[$i + 1], [ref]$v)) { Fail-Usage '--interval N' }; $interval = $v; $i += 2; continue }
      '--min-change' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--min-change N' }; $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '--min-change N' }; $minChange = $n; $i += 2; continue }
      '--threshold' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '--threshold N' }; $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '--threshold N' }; $threshold = $n; $i += 2; continue }
      '-D' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '-D N' }; $n = 0; if (-not [int]::TryParse($Rest[$i + 1], [ref]$n)) { Fail-Usage '-D N' }; $display = $n; $i += 2; continue }
      '-R' { if ($i + 1 -ge $Rest.Count) { Fail-Usage '-R X,Y,W,H' }; $o = ConvertFrom-RectString $Rest[$i + 1]; if ($null -eq $o) { Fail-Usage '-R X,Y,W,H' }; $rect = $o; $i += 2; continue }
      default { Fail-Usage ("未知选项: " + $Rest[$i]) }
    }
  }
  if (-not $text -and -not $stable -and -not $changePath) { Fail-Usage '需要 --text / --stable / --change 之一' }
  Initialize-Image

  $ref = $null
  if ($changePath) {
    if (-not (Test-Path -LiteralPath $changePath)) { Write-ErrLine ("无法读取参考图: " + $changePath); return 1 }
    try { $ref = [DshImg]::Load($changePath) } catch { Write-ErrLine ("无法读取参考图: " + $changePath); return 1 }
  }
  $ctx = New-CaptureContext -Display $display -Rect $rect
  $t0 = Get-Date
  $lastBmp = $null
  $lastHash = $null
  $iter = 0
  try {
    while (((Get-Date) - $t0).TotalSeconds -lt $timeout) {
      $iter++
      $bmp = $null
      try { $bmp = New-Capture -X $ctx.X -Y $ctx.Y -W $ctx.W -H $ctx.H } catch { Write-ErrLine '截图失败'; return 1 }
      $elapsed = ((Get-Date) - $t0).TotalSeconds
      try {
        if ($ref) {
          if (-not [DshImg]::SameSize($bmp, $ref)) { Write-ErrLine '参考图与当前截图尺寸不同，无法比较'; return 1 }
          $cnt = ([DshImg]::Diff($bmp, $ref, $threshold, 0, 0, $bmp.Width, $bmp.Height)).Changed
          if ($cnt -ge $minChange -and $lastBmp) {
            $delta = ([DshImg]::Diff($bmp, $lastBmp, $threshold, 0, 0, $bmp.Width, $bmp.Height)).Changed
            $limit = [math]::Max(20, [int]($cnt / 3))
            if ($delta -le $limit) {
              Write-Out ("ok 画面已变化并稳定（{0}s，变化 {1} 像素，帧间残留 {2}）" -f $elapsed.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture), $cnt, $delta)
              return 0
            }
          }
        }
        if ($stable) {
          $h = [DshImg]::Hash($bmp)
          if ($null -ne $lastHash -and $h -eq $lastHash) {
            Write-Out ("ok 画面稳定（{0}s）" -f $elapsed.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))
            return 0
          }
          $lastHash = $h
        }
        if ($text) {
          $capPath = [System.IO.Path]::Combine($env:TEMP, ("dsh-ui-wait-{0}.png" -f (Get-Random -Minimum 1000 -Maximum 999999)))
          try {
            [DshImg]::Save($bmp, $capPath)
            $lines = @(Get-OcrLines -Path $capPath -Lang $null)
            if ($null -ne $lines) {
              $ms = @(Find-OcrMatches -Lines $lines -Needle $text)
              if ($ms -and $ms.Count -gt 0) {
                Write-Out ("ok 找到「{0}」（{1}s）" -f $text, $elapsed.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))
                return 0
              }
            }
          } finally {
            if (Test-Path -LiteralPath $capPath) { Remove-Item -LiteralPath $capPath -Force -ErrorAction SilentlyContinue }
          }
        }
        if ($lastBmp) { $lastBmp.Dispose() }
        $lastBmp = $bmp
        $bmp = $null
      } finally {
        if ($bmp) { $bmp.Dispose() }
      }
      Start-Sleep -Milliseconds ([int]([math]::Max(50, $interval * 1000)))
    }
  } finally {
    if ($lastBmp) { $lastBmp.Dispose() }
    if ($ref) { $ref.Dispose() }
  }
  Write-ErrLine ("超时 {0}s：条件未满足" -f (To-Int $timeout))
  return 1
}

# =========================================================== 杂项层 ====
function Invoke-ClipboardCommand {
  param([string[]]$Rest)
  if ($Rest.Count -lt 1) { Fail-Usage 'clipboard get | set TEXT' }
  $sub = $Rest[0]
  if ($sub -eq 'get') {
    $t = ''
    try { $t = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { try { $t = [string](Get-Clipboard) } catch { $t = '' } }
    if ($null -eq $t) { $t = '' }
    Write-Out $t.TrimEnd("`r", "`n")
    return 0
  }
  if ($sub -eq 'set') {
    if ($Rest.Count -lt 2) { Fail-Usage 'clipboard set TEXT' }
    $text = ($Rest[1..($Rest.Count - 1)] -join ' ')
    if ($script:Dry) { Write-Out ("dry: would set clipboard ({0} 字符)" -f $text.Length); return 0 }
    Set-Clipboard -Value $text
    Write-Out ("ok clipboard set ({0} 字符)" -f $text.Length)
    return 0
  }
  Fail-Usage ("未知子命令: " + $sub)
}

function Invoke-GuardCommand {
  Initialize-StateDirs
  Write-Out ("拦截名单: " + $script:DenyFile)
  $entries = @(Get-DenyEntries)
  if ($entries.Count -eq 0) { Write-Out '  (空 — 未启用任何拦截)' }
  else { foreach ($e in $entries) { Write-Out ("  - " + $e) } }
  Write-Out ("审计日志: " + $script:AuditFile)
  $lines = @()
  try { $lines = @([System.IO.File]::ReadAllLines($script:AuditFile, [System.Text.Encoding]::UTF8) | Where-Object { $_ -ne '' }) } catch { }
  if ($lines.Count -gt 0) {
    Write-Out ("  已有 {0} 条记录，最近 3 条:" -f $lines.Count)
    $tail = $lines
    if ($tail.Count -gt 3) { $tail = $tail[($tail.Count - 3)..($tail.Count - 1)] }
    foreach ($l in $tail) { Write-Out ("    " + $l) }
  } else { Write-Out '  (暂无记录)' }
  Write-Out ("干跑模式: " + $(if ($script:Dry) { '开' } else { '关' }))
  Write-Out ("宿主: PowerShell {0} ({1})  OCR: {2}  DPI 感知: {3}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, (Initialize-Ocr), $script:DpiAware)
  return 0
}

# ---------------------------------------------------------- batch ----
function Split-DshArgs {
  param([string]$Line)
  $out = @()
  $cur = ''
  $has = $false
  $quote = [char]0
  foreach ($ch in $Line.ToCharArray()) {
    if ($quote -ne [char]0) {
      if ($ch -eq $quote) { $quote = [char]0; $has = $true }
      else { $cur += $ch; $has = $true }
      continue
    }
    if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; $has = $true; continue }
    if ($ch -eq ' ') {
      if ($has) { $out += $cur; $cur = ''; $has = $false }
      continue
    }
    $cur += $ch; $has = $true
  }
  if ($has) { $out += $cur }
  return $out
}

function Invoke-BatchCommand {
  param([string[]]$Rest)
  $keepGoing = $false
  foreach ($a in $Rest) { if ($a -eq '-c') { $keepGoing = $true } }
  $reader = [Console]::In
  $script_text = $reader.ReadToEnd()
  if ($null -eq $script_text) { Write-ErrLine '无法读取 stdin'; return 2 }
  $n = 0
  foreach ($rawLine in ($script_text -split "`n")) {
    $line = $rawLine.Trim().TrimEnd("`r")      # Windows 的 CRLF 要吃掉 \r（macOS 版没做，这里是有意修正）
    if ($line -eq '') { continue }
    if ($line.StartsWith('#')) { continue }
    $n++
    Write-Out ("> " + $line)
    $tokens = @(Split-DshArgs -Line $line)
    if ($tokens.Count -eq 0) { continue }
    $code = Invoke-DshCommand -Argv $tokens -FromBatch
    if ($code -ne 0) {
      Write-Out ("批量在第 {0} 条失败 (exit {1})" -f $n, $code)
      if (-not $keepGoing) { return $code }
    }
  }
  Write-Out ("ok 批量完成 {0} 条" -f $n)
  return 0
}

$script:HelpText = @'
dsh-ui (Windows) — 给 agent 用的桌面操作原语（macOS 版 dsh-ui.swift 的等价实现）

用法: dsh-ui [--dry] <命令> [参数...]

鼠标 / 键盘
  move   X Y
  click  X Y [MS] [--no-activate]     左键单击（默认 30ms；落点窗口不在前台时先激活）
  tap    X Y [MS]                     轻点（默认 60ms）
  press  X Y [MS]                     长按（默认 800ms）
  dclick X Y                          左键双击
  rclick X Y                          右键单击
  drag   X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N] [--momentum F] [--edge-guard N]
  scroll N [--drag] [--px-per-notch N]  滚轮默认 N 像素→按 100px/档 折算；--drag 用拖拽模拟
  type   TEXT                         输入文本（KEYEVENTF_UNICODE，绕过输入法，中文可用）
  keys   TEXT                         ASCII 逐字符发真实键码（大写/符号自动带 shift）
  key    KEY                          按键，如 key ctrl+shift+s / key enter / key win+r
  pos                                 打印光标位置

截图
  shot   [-D N] [-R X,Y,W,H] [-C] [-c] [-o PATH] [--grid [N]] [--zoom [N]]
  displays [--json]

定位
  find-text "文字" [--all] [--fast] [--click] [--list] [--json] [-D N] [-R X,Y,W,H] [--lang en-US]
  find-ax   "文字" [--app 名称] [--pid N] [--all] [--json] [--max N] [--click]
  win    list [--json] | focus N | maximize N | fullscreen N | move N X Y [W H] | close N | minimize N | restore N

验证
  wait-for --text "文字" [--timeout 20] [--interval 0.6]
  wait-for --stable [--timeout 20]
  wait-for --change PATH [--timeout 20] [--min-change 2000] [--threshold 12]
  diff   A.png B.png [--threshold 12] [-D N] [-R X,Y,W,H]

其他
  clipboard get | set TEXT
  batch  [-c]                         从 stdin 读脚本逐条执行（# 开头是注释）
  guard                               查看拦截名单、审计日志、干跑状态
  under  X Y                          该坐标下是哪个窗口/元素
  --dry  <任意命令>                   干跑：只打印动作，不执行

退出码: 0 成功 / 1 未命中或超时 / 2 用法错误 / 3 被拦截名单拒绝
注意: type / keys / key 与滚轮 scroll 成功时不打印任何内容（与 macOS 版一致）。
'@

# ========================================================== 分发层 ====
class DshExitException : System.Exception {
  [int]$Code
  DshExitException([int]$Code, [string]$Message) : base($Message) { $this.Code = $Code }
}

function Invoke-Dispatch {
  param([string[]]$Tokens)
  $cmd = $Tokens[0].ToLowerInvariant()
  $rest = @()
  if ($Tokens.Count -gt 1) { $rest = $Tokens[1..($Tokens.Count - 1)] }
  switch ($cmd) {
    'help' { Write-Out $script:HelpText; return 0 }
    '-h' { Write-Out $script:HelpText; return 0 }
    '--help' { Write-Out $script:HelpText; return 0 }
    '--version' { Write-Out ("dsh-ui (Windows) " + $script:Version); return 0 }
    'displays' { return (Invoke-DisplaysCommand -Rest $rest) }
    'pos' { return (Invoke-PosCommand) }
    'move' { return (Invoke-MoveCommand -Rest $rest) }
    'click' { return (Invoke-ClickCommand -Cmd 'click' -Rest $rest) }
    'tap' { return (Invoke-ClickCommand -Cmd 'tap' -Rest $rest) }
    'press' { return (Invoke-ClickCommand -Cmd 'press' -Rest $rest) }
    'dclick' { return (Invoke-ClickCommand -Cmd 'dclick' -Rest $rest) }
    'rclick' { return (Invoke-ClickCommand -Cmd 'rclick' -Rest $rest) }
    'drag' { return (Invoke-DragCommand -Rest $rest) }
    'scroll' { return (Invoke-ScrollCommand -Rest $rest) }
    'type' { return (Invoke-TypeCommand -Rest $rest) }
    'keys' { return (Invoke-KeysCommand -Rest $rest) }
    'key' { return (Invoke-KeyCommand -Rest $rest) }
    'shot' { return (Invoke-ShotCommand -Rest $rest) }
    'find-text' { return (Invoke-FindTextCommand -Rest $rest) }
    'find-ax' { return (Invoke-FindAxCommand -Rest $rest) }
    'win' { return (Invoke-WinCommand -Rest $rest) }
    'wait-for' { return (Invoke-WaitForCommand -Rest $rest) }
    'diff' { return (Invoke-DiffCommand -Rest $rest) }
    'clipboard' { return (Invoke-ClipboardCommand -Rest $rest) }
    'batch' { return (Invoke-BatchCommand -Rest $rest) }
    'guard' { return (Invoke-GuardCommand) }
    'under' { return (Invoke-UnderCommand -Rest $rest) }
    default {
      Write-ErrLine ("未知命令: " + $Tokens[0])
      Write-Out $script:HelpText
      return 2
    }
  }
}

function Invoke-DshCommand {
  param([string[]]$Argv, [string]$AuditCommand)
  if (-not $AuditCommand) { $AuditCommand = ($Argv -join ' ') }
  # --dry 是全局开关，可以出现在任意位置；只摘掉第一个（与 macOS 版一致）
  $tokens = @()
  $seen = $false
  foreach ($t in $Argv) {
    if ($t -eq '--dry' -and -not $seen) { $seen = $true; $script:Dry = $true; continue }
    $tokens += $t
  }
  $code = 0
  if ($tokens.Count -eq 0) {
    Write-Out $script:HelpText
    $code = 2
  } else {
    try {
      $code = Invoke-Dispatch -Tokens $tokens
      if ($null -eq $code) { $code = 0 }
    } catch {
      $ex = $_.Exception
      if ($ex -is [DshExitException]) { $code = $ex.Code }
      else {
        Write-ErrLine ("内部错误: " + $ex.Message)
        $code = 2
      }
    }
  }
  Add-Audit -Command $AuditCommand -Code ([int]$code)
  return [int]$code
}

# ============================================================ 入口 ====
$script:DpiAware = $false

# OCR worker：只有 Windows PowerShell 5.1 能加载 WinRT OCR。
# dsh-ui.ps1 在 PS7 下跑 find-text 时，会用 5.1 派生自己当 worker，结果走 JSON 文件回传。
if ($script:Argv.Count -ge 4 -and $script:Argv[0] -eq '__ocr') {
  $png = $script:Argv[1]
  $langArg = $script:Argv[2]
  $outArg = $script:Argv[3]
  if ($langArg -eq 'auto') { $langArg = $null }
  exit (Invoke-OcrWorkerMode -Path $png -Lang $langArg -Out $outArg)
}

Initialize-Native
$script:Note = ''
$code = Invoke-DshCommand -Argv $script:Argv -AuditCommand ($script:Argv -join ' ')
exit $code
