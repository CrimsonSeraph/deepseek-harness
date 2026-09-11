#Requires -Version 5.1
<#
.SYNOPSIS
  按窗口标题（可选按进程过滤）定位可见窗口，抓取该窗口自身位图并存为 PNG。

.DESCRIPTION
  窗口查找带硬超时：在 -TimeoutSec 秒内找不到就立刻以退出码 1 结束，不做无限轮询。
  默认只接受 IsWindowVisible 为真的窗口 —— 隐藏窗口（例如同名但 visible: false 的兄弟
  窗口）还没开始绘制，抓到的是纯背景色，属于典型的「命令成功但图是空白」。

  抓图默认走 PrintWindow(PW_RENDERFULLCONTENT)，按窗口句柄取内容而不是抓全屏，
  因此不会被其它窗口遮挡，也不会把桌面上无关内容拍进图里。

  每次抓图都做客户区空白检测（网格采样，主色占比 >= -BlankRatio 判为空白）；
  空白时先 RedrawWindow 强制重绘再重试，仍失败则依次退化到
  PrintWindow(兼容标志) → BitBlt(窗口 DC) → CopyFromScreen(窗口矩形，需显式开启)，
  全部失败以退出码 5 结束，避免“成功但图是白屏/黑屏”的静默失败。

  -List 只枚举候选窗口，用于排查“窗口找不到”。

.EXAMPLE
  powershell -NoProfile -File cap.ps1 -TitlePart SHOTWIN -OutPath C:\tmp\shot.png
.EXAMPLE
  powershell -NoProfile -File cap.ps1 -TitlePart SHOTWIN -TargetPid 1234 -TimeoutSec 15 -OutPath C:\tmp\shot.png
.EXAMPLE
  powershell -NoProfile -File cap.ps1 -TitlePart SHOTWIN -List -IncludeHidden

.OUTPUTS
  成功：OK hwnd=0x000A1234 pid=1234 title="SHOTWIN" size=1180x760 dpi=120 method=printwindow bytes=64080 file=...
  失败：ERROR <退出码> <原因>    （也写标准输出，便于调用方统一捕获）

.EXITCODE
  0  成功
  1  在 -TimeoutSec 内未找到窗口（含枚举不到任何标题匹配的可见窗口）
  2  窗口矩形非法（宽或高 <= 0）
  3  抓图失败（PrintWindow / BitBlt / CopyFromScreen 全部失败或抛异常）
  4  PNG 未写出、为空或小于 -MinBytes
  5  抓到空白帧（客户区整幅同色）
  6  内部错误（Add-Type、System.Drawing、GDI+ 初始化失败）
  7  指定的 -TargetPid 进程已退出（窗口不会再出现，立即失败而不是等满超时）
#>
[CmdletBinding()]
param(
    # 目标窗口标题需要包含的子串（区分大小写；-Exact 时要求完全相等）
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TitlePart,

    # 输出 PNG 路径（Windows 路径）。-List 时可省略
    [Parameter(Position = 1)]
    [string]$OutPath = '',

    # 等待窗口出现的上限秒数；从脚本启动算起，超时即以退出码 1 结束，绝不无限等待
    [ValidateRange(1, 600)]
    [int]$TimeoutSec = 10,

    # 轮询间隔毫秒
    [ValidateRange(20, 5000)]
    [int]$PollMs = 200,

    # 找到窗口后等待其完成首次绘制的毫秒数
    [ValidateRange(0, 10000)]
    [int]$SettleMs = 600,

    # 抓图后判定“非空文件”的最小字节数
    [ValidateRange(0, 1073741824)]
    [int]$MinBytes = 512,

    # 只接受属于该 Windows PID 的窗口；进程退出即返回 7（0 表示不按进程过滤）
    [int]$TargetPid = 0,

    # 标题完全相等才算匹配（默认是包含匹配）
    [switch]$Exact,

    # 只枚举候选窗口，不抓图
    [switch]$List,

    # 允许把隐藏窗口也算作候选（仅用于排查；隐藏窗口通常还没绘制）
    [switch]$IncludeHidden,

    # 关闭空白帧检测（不推荐）
    [switch]$NoBlankCheck,

    # 客户区主色占比达到该值即判为空白帧
    [ValidateRange(0.5, 1.0)]
    [double]$BlankRatio = 0.995,

    # 空白帧重试次数（每次先强制重绘再抓图）
    [ValidateRange(1, 20)]
    [int]$CaptureRetries = 5,

    # 空白帧重试间隔毫秒
    [ValidateRange(0, 5000)]
    [int]$RetryDelayMs = 400,

    # 允许最后退化为 CopyFromScreen(窗口矩形) 抓屏；默认关闭
    [switch]$AllowScreenFallback,

    # 仅当宿主进程 DPI 感知声明失败时才需要；按注册表缩放还原物理像素
    [switch]$LegacyDpiScale,

    # 只输出最终结果行，不输出诊断行
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Diag([string]$Message) {
    if (-not $Quiet) { Write-Output ("DBG " + $Message) }
}

function Fail([int]$Code, [string]$Message) {
    Write-Output ("ERROR " + $Code + " " + $Message)
    exit $Code
}

# 超时预算从脚本一开始就算：Add-Type 编译与 PowerShell 启动都算在 TimeoutSec 之内，
# 调用方因此可以把 TimeoutSec 当作硬上限，而不是「超时 + 未知开销」。
$script:Deadline = (Get-Date).AddSeconds($TimeoutSec)

# ---------------------------------------------------------------- 前置环境
try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}
catch {
    Write-Output ("ERROR 6 System.Drawing 加载失败: " + $_.Exception.Message)
    exit 6
}

try {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WindowInfo {
    public IntPtr Hwnd = IntPtr.Zero;
    public string Title = "";
    public uint Pid = 0;
    public bool Visible = false;
    public bool Iconized = false;
    public int Width = 0;
    public int Height = 0;
    public long Area = 0;
}

public class QtShotWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr region, uint flags);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);

    /// 枚举标题匹配的窗口；pid 非 0 时只保留属于该进程的窗口；requireVisible 时只保留可见窗口。
    /// 结果按「可见优先、面积从大到小」排序。
    public static List<WindowInfo> FindAll(string part, bool exact, uint pid, bool requireVisible) {
        List<WindowInfo> hits = new List<WindowInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            StringBuilder sb = new StringBuilder(1024);
            GetWindowTextW(h, sb, sb.Capacity);
            string title = sb.ToString();
            if (title.Length == 0) return true;
            bool match = exact ? title.Equals(part, StringComparison.Ordinal) : title.Contains(part);
            if (!match) return true;
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (pid != 0 && owner != pid) return true;
            bool visible = IsWindowVisible(h);
            if (requireVisible && !visible) return true;
            RECT r; GetWindowRect(h, out r);
            WindowInfo info = new WindowInfo();
            info.Hwnd = h;
            info.Title = title;
            info.Pid = owner;
            info.Visible = visible;
            info.Iconized = IsIconic(h);
            info.Width = r.Right - r.Left;
            info.Height = r.Bottom - r.Top;
            info.Area = (long)info.Width * (long)info.Height;
            hits.Add(info);
            return true;
        }, IntPtr.Zero);
        hits.Sort(delegate(WindowInfo a, WindowInfo b) {
            if (a.Visible != b.Visible) return a.Visible ? -1 : 1;
            return b.Area.CompareTo(a.Area);
        });
        return hits;
    }
}
"@ -ErrorAction Stop
}
catch {
    Write-Output ("ERROR 6 P/Invoke 类型编译失败: " + $_.Exception.Message)
    exit 6
}

# ---------------------------------------------------------------- DPI 感知
$awareness = 'unknown'
try {
    # -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2，-2 = PER_MONITOR_AWARE
    if ([QtShotWin]::SetProcessDpiAwarenessContext([IntPtr](-4))) { $awareness = 'per-monitor-v2' }
    elseif ([QtShotWin]::SetProcessDpiAwarenessContext([IntPtr](-2))) { $awareness = 'per-monitor' }
    elseif ([QtShotWin]::SetProcessDPIAware()) { $awareness = 'system' }
}
catch {
    # 进程级 DPI 感知只能设置一次；宿主已声明时会抛错，属正常情况
    $awareness = 'already-set'
}
if ($awareness -eq 'unknown') { $awareness = 'already-set' }
Write-Diag ("dpiAwareness=" + $awareness)

# ---------------------------------------------------------------- 窗口枚举
# $Pid 是 PowerShell 只读自动变量，这里用 OwnerPid 命名
function Get-CandidateWindows([string]$Part, [bool]$ExactMatch, [int]$OwnerPid) {
    return [QtShotWin]::FindAll($Part, $ExactMatch, [uint32]$OwnerPid, (-not $IncludeHidden))
}

if ($List) {
    $all = Get-CandidateWindows $TitlePart $Exact.IsPresent $TargetPid
    if ($all.Count -eq 0) {
        Write-Output ("ERROR 1 未找到标题包含 [" + $TitlePart + "] 的窗口")
        exit 1
    }
    foreach ($w in $all) {
        Write-Output ("HWND 0x" + $w.Hwnd.ToInt64().ToString("X8") +
            " pid=" + $w.Pid +
            " visible=" + $w.Visible +
            " iconic=" + $w.Iconized +
            " area=" + $w.Area +
            " rect=" + $w.Width + "x" + $w.Height +
            " title=[" + $w.Title + "]")
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($OutPath)) {
    Fail 2 "-OutPath 不能为空（-List 模式除外）"
}

# ---------------------------------------------------------------- 等待窗口
Write-Diag ("wait visible hwnd title~[" + $TitlePart + "] pid=" + $TargetPid + " timeout=" + $TimeoutSec + "s")

$target = $null
while ($true) {
    $found = Get-CandidateWindows $TitlePart $Exact.IsPresent $TargetPid
    if ($found.Count -gt 0) { $target = $found[0]; break }

    if ($TargetPid -gt 0) {
        $proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            Fail 7 ("目标进程 pid=" + $TargetPid + " 已退出，窗口不会出现")
        }
    }

    if ((Get-Date) -ge $script:Deadline) { break }
    Start-Sleep -Milliseconds $PollMs
}

if ($null -eq $target) {
    $hint = ''
    if (-not $IncludeHidden) {
        $hidden = [QtShotWin]::FindAll($TitlePart, $Exact.IsPresent, [uint32]$TargetPid, $false)
        if ($hidden.Count -gt 0) {
            $hint = "（存在同名但不可见的窗口：多半是 visible: false 的兄弟窗口，或窗口尚未显示）"
        }
    }
    Fail 1 ("在 " + $TimeoutSec + "s 内未找到标题包含 [" + $TitlePart + "] 的可见窗口" + $hint)
}

Write-Diag ("found hwnd=0x" + $target.Hwnd.ToInt64().ToString("X8") + " pid=" + $target.Pid + " title=[" + $target.Title + "]")

# 置前并还原（PrintWindow 对最小化窗口不可靠）
if ($target.Iconized) { [void][QtShotWin]::ShowWindow($target.Hwnd, 9) }   # SW_RESTORE
[void][QtShotWin]::ShowWindow($target.Hwnd, 5)                            # SW_SHOW
[void][QtShotWin]::BringWindowToTop($target.Hwnd)
[void][QtShotWin]::SetForegroundWindow($target.Hwnd)
# SWP_NOSIZE(0x1) | SWP_NOMOVE(0x2) | SWP_SHOWWINDOW(0x40)
[void][QtShotWin]::SetWindowPos($target.Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0043)

if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }

# ---------------------------------------------------------------- 计算尺寸
$rect = New-Object QtShotWin+RECT
if (-not [QtShotWin]::GetWindowRect($target.Hwnd, [ref]$rect)) {
    Fail 2 "GetWindowRect 调用失败"
}

$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) {
    Fail 2 ("窗口矩形非法: " + $w + "x" + $h)
}

$dpi = 96
try { $dpi = [int][QtShotWin]::GetDpiForWindow($target.Hwnd) } catch { $dpi = 96 }
if ($dpi -le 0) { $dpi = 96 }

# 宿主进程若不是 DPI 感知，GetWindowRect 给出的是缩放后的逻辑像素，需按系统缩放还原
if ($LegacyDpiScale) {
    $applied = 96
    try {
        $applied = [int](Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop).AppliedDPI
    }
    catch { $applied = 96 }
    if ($applied -le 0) { $applied = 96 }
    if ($applied -ne 96) {
        $scale = $applied / 96.0
        $w = [int][Math]::Round($w * $scale)
        $h = [int][Math]::Round($h * $scale)
        Write-Diag ("legacyDpiScale applied=" + $applied + " scale=" + $scale)
    }
}

# 客户区在窗口位图中的位置：空白检测只看客户区，避开标题栏/边框的干扰
$clientRect = New-Object QtShotWin+RECT
[void][QtShotWin]::GetClientRect($target.Hwnd, [ref]$clientRect)
$clientOrigin = New-Object QtShotWin+POINT
$clientOrigin.X = 0
$clientOrigin.Y = 0
[void][QtShotWin]::ClientToScreen($target.Hwnd, [ref]$clientOrigin)
$clientX = $clientOrigin.X - $rect.Left
$clientY = $clientOrigin.Y - $rect.Top
$clientW = $clientRect.Right - $clientRect.Left
$clientH = $clientRect.Bottom - $clientRect.Top
if ($clientW -le 0 -or $clientH -le 0 -or $clientX -lt 0 -or $clientY -lt 0) {
    # 取不到客户区时退化为整幅检测
    $clientX = 0
    $clientY = 0
    $clientW = $w
    $clientH = $h
}

Write-Diag ("rect=" + $w + "x" + $h + " client=" + $clientW + "x" + $clientH + "@" + $clientX + "," + $clientY + " dpi=" + $dpi)

# ---------------------------------------------------------------- 抓图
function Test-BlankFrame([System.Drawing.Bitmap]$Bitmap, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Grid, [double]$Ratio) {
    if ($W -le 2 -or $H -le 2) { return $true }
    $counts = @{}
    $total = 0
    for ($i = 0; $i -lt $Grid; $i++) {
        $px = $X + [int](($W - 1) * $i / ($Grid - 1))
        for ($j = 0; $j -lt $Grid; $j++) {
            $py = $Y + [int](($H - 1) * $j / ($Grid - 1))
            if ($px -lt 0 -or $py -lt 0 -or $px -ge $Bitmap.Width -or $py -ge $Bitmap.Height) { continue }
            $argb = $Bitmap.GetPixel($px, $py).ToArgb()
            if ($counts.ContainsKey($argb)) { $counts[$argb] = $counts[$argb] + 1 } else { $counts[$argb] = 1 }
            $total++
        }
    }
    if ($total -eq 0) { return $true }
    $max = 0
    foreach ($v in $counts.Values) { if ($v -gt $max) { $max = $v } }
    return (($max / [double]$total) -ge $Ratio)
}

function New-Capture([IntPtr]$Hwnd, [int]$Width, [int]$Height, [string]$Method) {
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        switch ($Method) {
            'printwindow' {
                $hdc = $gfx.GetHdc()
                try { $ok = [QtShotWin]::PrintWindow($Hwnd, $hdc, 0x00000002) }   # PW_RENDERFULLCONTENT
                finally { $gfx.ReleaseHdc($hdc) }
                if (-not $ok) { throw "PrintWindow(PW_RENDERFULLCONTENT) 返回 false" }
            }
            'printwindow-legacy' {
                $hdc = $gfx.GetHdc()
                try { $ok = [QtShotWin]::PrintWindow($Hwnd, $hdc, 0x00000000) }
                finally { $gfx.ReleaseHdc($hdc) }
                if (-not $ok) { throw "PrintWindow(0) 返回 false" }
            }
            'bitblt' {
                $src = [QtShotWin]::GetWindowDC($Hwnd)
                if ($src -eq [IntPtr]::Zero) { throw "GetWindowDC 返回 0" }
                try {
                    $hdc = $gfx.GetHdc()
                    try { $ok = [QtShotWin]::BitBlt($hdc, 0, 0, $Width, $Height, $src, 0, 0, 0x00CC0020) }  # SRCCOPY
                    finally { $gfx.ReleaseHdc($hdc) }
                }
                finally { [void][QtShotWin]::ReleaseDC($Hwnd, $src) }
                if (-not $ok) { throw "BitBlt(SRCCOPY) 返回 false" }
            }
            'screen' {
                $gfx.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size($Width, $Height)))
            }
            default { throw ("未知抓图方式 " + $Method) }
        }
    }
    catch {
        $gfx.Dispose()
        $bmp.Dispose()
        throw
    }
    $gfx.Dispose()
    return $bmp
}

$methods = @('printwindow', 'printwindow-legacy', 'bitblt')
if ($AllowScreenFallback) {
    [void][QtShotWin]::SetForegroundWindow($target.Hwnd)
    $methods += 'screen'
}

$bitmap = $null
$usedMethod = ''
$blank = $false
$lastError = ''

foreach ($method in $methods) {
    $attempt = 0
    while ($attempt -lt $CaptureRetries) {
        $attempt++
        # 强制窗口立即重绘：刚显示出来的窗口常常还没画第一帧，抓到的就是纯背景色
        [void][QtShotWin]::RedrawWindow($target.Hwnd, [IntPtr]::Zero, [IntPtr]::Zero, 0x0185)  # INVALIDATE|ERASE|ALLCHILDREN|UPDATENOW

        try {
            $candidate = New-Capture $target.Hwnd $w $h $method
        }
        catch {
            $lastError = ($method + ": " + $_.Exception.Message)
            Write-Diag ("capture-failed method=" + $method + " attempt=" + $attempt + " " + $_.Exception.Message)
            break
        }

        $isBlank = $false
        if (-not $NoBlankCheck) {
            $isBlank = Test-BlankFrame $candidate $clientX $clientY $clientW $clientH 24 $BlankRatio
        }
        if ($isBlank) {
            $lastError = ($method + ": 客户区为空白帧（主色占比 >= " + $BlankRatio + "）")
            if ($null -eq $bitmap) { $bitmap = $candidate } else { $candidate.Dispose() }
            Write-Diag ("blank-frame method=" + $method + " attempt=" + $attempt)
            if ($RetryDelayMs -gt 0) { Start-Sleep -Milliseconds $RetryDelayMs }
            continue
        }

        if ($null -ne $bitmap) { $bitmap.Dispose() }
        $bitmap = $candidate
        $usedMethod = $method
        break
    }
    if ($usedMethod -ne '') { break }
}

if ($usedMethod -eq '') {
    if ($null -eq $bitmap) {
        Fail 3 ("抓图失败: " + $lastError)
    }
    $blank = $true
}

# ---------------------------------------------------------------- 保存
$dir = Split-Path -Parent $OutPath
if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
    try { [void](New-Item -ItemType Directory -Force -Path $dir) }
    catch { Fail 4 ("输出目录创建失败 " + $dir + ": " + $_.Exception.Message) }
}
if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }

try {
    $bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
catch {
    Fail 3 ("PNG 保存失败: " + $_.Exception.Message)
}
finally {
    $bitmap.Dispose()
}

if (-not (Test-Path -LiteralPath $OutPath)) { Fail 4 ("PNG 未写出: " + $OutPath) }
$bytes = (Get-Item -LiteralPath $OutPath).Length
if ($bytes -lt $MinBytes) { Fail 4 ("PNG 过小 (" + $bytes + " < " + $MinBytes + " 字节): " + $OutPath) }

if ($blank) {
    Fail 5 ("客户区为空白帧（各抓图方式与重试后仍为同色），调试图已保存: " + $OutPath)
}

Write-Output ("OK hwnd=0x" + $target.Hwnd.ToInt64().ToString("X8") +
    " pid=" + $target.Pid +
    " title=[" + $target.Title + "]" +
    " size=" + $w + "x" + $h +
    " dpi=" + $dpi +
    " method=" + $usedMethod +
    " bytes=" + $bytes +
    " file=" + $OutPath)
exit 0
