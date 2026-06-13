# ============================================================
#  C盘清理工具  CClean.ps1
#  运行环境: Windows 10/11 自带 PowerShell 5.1 + WPF
#  说明: 请通过 "一键清理C盘.bat" 启动 (会自动提权)
# ============================================================

# 保存为 UTF-8 BOM, 避免中文乱码
# 日志文件路径 (记录运行时错误, 方便排查闪退问题)
$Global:LogFile = Join-Path $PSScriptRoot ('CClean_' + [DateTime]::Now.ToString('yyyyMMdd_HHmmss') + '.log')

function Write-Log {
    param([string]$Msg)
    try {
        $line = "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
        [System.IO.File]::AppendAllText($Global:LogFile, $line + "`n")

        # 日志轮转: 保留最近 10 个日志文件，删除更早的
        $logFiles = Get-ChildItem -Path $PSScriptRoot -Filter 'CClean_*.log' -File |
                    Sort-Object Name -Descending | Select-Object -Skip 10 -ExpandProperty FullName
        foreach ($old in $logFiles) {
            try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop } catch {}
        }
    } catch {}
}

# 不再用 Stop 全局, 改为逐处 try/catch, 避免未捕获的异常直接炸掉进程
$ErrorActionPreference = 'Continue'

# ---------- 加载 WPF 程序集 ----------
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
} catch {
    Write-Log "WPF加载失败: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show("无法加载界面组件, 您的系统可能缺少 .NET 桌面运行时。`n$($_.Exception.Message)`n`n日志: $Global:LogFile")
    exit 1
}

# ============================================================
#  公共辅助函数
# ============================================================

# 字节数转人类可读
function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

# 计算目录大小 (忽略无权限/被占用, 不抛异常)
function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    } catch { return 0 }
}

# 安全白名单: 删除路径必须位于这些前缀之内, 杜绝误删根目录/系统盘
$Global:SafeRoots = @(
    $env:TEMP,
    "$env:SystemRoot\Temp",
    "$env:SystemRoot\Prefetch",
    "$env:SystemRoot\SoftwareDistribution\Download",
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "$env:USERPROFILE",
    "C:\Users"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

# 系统关键目录黑名单: 永不进入/删除 (扫描和删除都跳过, 防止误删与扫描卡死)
$Global:ProtectedPaths = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:SystemRoot\WinSxS",
    "$env:SystemRoot\Fonts",
    "$env:SystemRoot\assembly",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}",
    "C:\ProgramData\Microsoft\Windows\Start Menu"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

# 判断路径是否在安全白名单内
function Test-SafeToDelete {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.TrimEnd('\').ToLower()
    # 绝不允许删除盘符根 / 过短路径
    if ($p.Length -lt 6) { return $false }
    if ($p -match '^[a-z]:\\?$') { return $false }
    # 命中保护目录则拒绝
    foreach ($prot in $Global:ProtectedPaths) {
        if ($p -eq $prot -or $p.StartsWith($prot + '\')) { return $false }
    }
    # 必须位于某个安全根之下
    foreach ($root in $Global:SafeRoots) {
        if ($p -eq $root -or $p.StartsWith($root + '\')) { return $true }
    }
    return $false
}

# 判断路径是否为受保护(扫描时跳过)
function Test-Protected {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $p = $Path.TrimEnd('\').ToLower()
    foreach ($prot in $Global:ProtectedPaths) {
        if ($p -eq $prot -or $p.StartsWith($prot + '\')) { return $true }
    }
    return $false
}

# 获取当前运行进程对应的可执行文件目录集合 (用于残留识别: 正在运行的不算残留)
function Get-RunningProcessDirs {
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    try {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $path = $_.Path
                if ($path) {
                    [void]$dirs.Add(([System.IO.Path]::GetDirectoryName($path)).ToLower())
                }
            } catch {}
        }
    } catch {}
    return $dirs
}

# ============================================================
#  残留识别 - 内置易残留软件白名单
#  仅扫描这些已知目录, 误报率最低
# ============================================================
# 每项: Name=显示名, Paths=候选目录(相对 AppData 等)
$Global:ResidualTargets = @(
    @{ Name='360安全卫士残留';   Roots=@("$env:APPDATA\360safe", "$env:LOCALAPPDATA\360safe", "$env:ProgramData\360safe") }
    @{ Name='360浏览器残留';     Roots=@("$env:APPDATA\360se6", "$env:LOCALAPPDATA\360Chrome", "$env:APPDATA\360se") }
    @{ Name='钉钉(DingTalk)旧版'; Roots=@("$env:APPDATA\DingTalk", "$env:LOCALAPPDATA\DingTalk") }
    @{ Name='企业微信残留';      Roots=@("$env:APPDATA\Tencent\WXWork") }
    @{ Name='各类Updater残留';   Roots=@("$env:LOCALAPPDATA\Updater", "$env:LOCALAPPDATA\Update") }
    @{ Name='搜狗输入法残留';    Roots=@("$env:APPDATA\SogouInput", "$env:LOCALAPPDATA\SogouInput") }
    @{ Name='WPS旧版缓存';       Roots=@("$env:LOCALAPPDATA\Kingsoft\WPS\addons", "$env:APPDATA\kingsoft\office6\backup") }
    @{ Name='迅雷残留';          Roots=@("$env:APPDATA\Thunder Network", "$env:LOCALAPPDATA\Thunder Network") }
    @{ Name='百度网盘缓存残留';  Roots=@("$env:APPDATA\baidu\BaiduNetdisk", "$env:LOCALAPPDATA\baidu") }
)

# ============================================================
#  扫描各清理项 (只读, 不删)
#  返回项: @{ Key; Name; Size; Paths(数组); Risk; Detail; Checked(默认) }
# ============================================================

function Scan-TempFiles {
    $paths = @($env:TEMP, "$env:SystemRoot\Temp", "$env:SystemRoot\Prefetch") |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $size = 0
    foreach ($p in $paths) { $size += Get-FolderSize $p }
    return @{ Key='temp'; Name='系统/用户临时文件'; Size=$size; Paths=$paths; Risk='低'; Mode='content'; Detail='%TEMP%, Windows\Temp, Prefetch'; Checked=$true }
}

function Scan-RecycleBin {
    $size = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $rb = $shell.NameSpace(0x0a)
        if ($rb) { foreach ($item in $rb.Items()) { try { $size += $item.Size } catch {} } }
    } catch {}
    return @{ Key='recyclebin'; Name='回收站'; Size=$size; Paths=@(); Risk='低'; Mode='recyclebin'; Detail='清空所有磁盘的回收站'; Checked=$true }
}

function Scan-BrowserCache {
    $cachePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
    )
    # Firefox 缓存(多 profile)
    $ffRoot = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ffRoot) {
        Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $cachePaths += (Join-Path $_.FullName 'cache2')
        }
    }
    $paths = $cachePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
    $size = 0
    foreach ($p in $paths) { $size += Get-FolderSize $p }
    return @{ Key='browser'; Name='浏览器缓存(Chrome/Edge/Firefox)'; Size=$size; Paths=$paths; Risk='低'; Mode='content'; Detail='仅清缓存, 不动密码/书签/历史'; Checked=$true }
}

function Scan-WindowsUpdate {
    $paths = @("$env:SystemRoot\SoftwareDistribution\Download", "$env:SystemRoot\Logs\CBS") |
             Where-Object { Test-Path -LiteralPath $_ }
    $size = 0
    foreach ($p in $paths) { $size += Get-FolderSize $p }
    return @{ Key='winupdate'; Name='Windows更新缓存/日志'; Size=$size; Paths=$paths; Risk='中'; Mode='content'; Detail='更新下载缓存与CBS日志(默认不勾选)'; Checked=$false }
}

# 大日志文件: 限定常见日志目录扫描, 跳过系统保护目录, 避免全盘遍历卡死
function Scan-BigLogs {
    param([double]$ThresholdMB = 50)
    $threshold = $ThresholdMB * 1MB
    $searchRoots = @(
        "$env:LOCALAPPDATA",
        "$env:APPDATA",
        "$env:ProgramData",
        "$env:SystemRoot\Logs"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

    $bigFiles = New-Object System.Collections.Generic.List[object]
    $size = 0
    foreach ($root in $searchRoots) {
        try {
            Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.log','*.etl','*.dmp' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $threshold -and -not (Test-Protected $_.DirectoryName) } |
            ForEach-Object {
                $bigFiles.Add($_.FullName) | Out-Null
                $size += $_.Length
            }
        } catch {}
    }
    return @{ Key='biglogs'; Name="大日志文件(>$ThresholdMB MB)"; Size=$size; Paths=$bigFiles; Risk='中'; Mode='files'; Detail="$($bigFiles.Count) 个大日志/转储文件(默认不勾选)"; Checked=$false }
}

# 应用残留智能识别 (白名单 + 时间戳 + 运行进程检测 + 分级)
function Scan-Residual {
    param([int]$Days = 90)
    $cutoff = (Get-Date).AddDays(-$Days)
    $running = Get-RunningProcessDirs
    $found = New-Object System.Collections.Generic.List[object]
    $totalSize = 0

    foreach ($target in $Global:ResidualTargets) {
        foreach ($root in $target.Roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            try {
                $item = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
                if (-not $item) { continue }
                $last = $item.LastWriteTime
                # 旧版判定: 超过阈值未修改
                if ($last -gt $cutoff) { continue }
                # 正在运行的目录跳过
                if ($running.Contains($root.ToLower())) { continue }
                $sz = Get-FolderSize $root
                if ($sz -le 0) { continue }
                $found.Add([pscustomobject]@{
                    Name = $target.Name
                    Path = $root
                    Size = $sz
                    LastWrite = $last
                }) | Out-Null
                $totalSize += $sz
            } catch {}
        }
    }
    $paths = $found | ForEach-Object { $_.Path }
    $detailLines = $found | ForEach-Object { "  $($_.Name)  |  $(Format-Size $_.Size)  |  最后修改 $($_.LastWrite.ToString('yyyy-MM-dd'))  |  $($_.Path)" }
    $detail = if ($found.Count -gt 0) { ($detailLines -join "`n") } else { '未发现疑似残留' }
    return @{ Key='residual'; Name="应用残留(>$Days 天未用)"; Size=$totalSize; Paths=@($paths); Risk='高'; Mode='folder'; Detail=$detail; Checked=$false; Items=$found }
}

# 大文件夹 Top10 (C盘根 + Users 下), 跳过保护目录
function Scan-BigFolders {
    $roots = @("C:\", "C:\Users") | Select-Object -Unique
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        try {
            Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Protected $_.FullName) } |
            ForEach-Object {
                $sz = Get-FolderSize $_.FullName
                if ($sz -gt 0) {
                    $results.Add([pscustomobject]@{ Path=$_.FullName; Size=$sz }) | Out-Null
                }
            }
        } catch {}
    }
    return ($results | Sort-Object Size -Descending | Select-Object -First 10)
}

# ============================================================
#  后台引擎 — Runspace + DispatcherTimer 轮询
#  所有扫描在后台 Runspace 中执行，不阻塞 UI 线程
# ============================================================

# initScript：预加载到每个后台 Runspace 的扫描函数和数据
# （与主脚本同步，每个任务运行时创建独立的 Runspace，避免并发冲突）
$initScript = @'
$Global:SafeRoots = @(
    $env:TEMP,
    "$env:SystemRoot\Temp",
    "$env:SystemRoot\Prefetch",
    "$env:SystemRoot\SoftwareDistribution\Download",
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "$env:USERPROFILE",
    "C:\Users"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

$Global:ProtectedPaths = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:SystemRoot\WinSxS",
    "$env:SystemRoot\Fonts",
    "$env:SystemRoot\assembly",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}",
    "C:\ProgramData\Microsoft\Windows\Start Menu"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLower() }

$Global:ResidualTargets = @(
    @{ Name='360安全卫士残留';   Roots=@("$env:APPDATA\360safe", "$env:LOCALAPPDATA\360safe", "$env:ProgramData\360safe") }
    @{ Name='360浏览器残留';     Roots=@("$env:APPDATA\360se6", "$env:LOCALAPPDATA\360Chrome", "$env:APPDATA\360se") }
    @{ Name='钉钉(DingTalk)旧版'; Roots=@("$env:APPDATA\DingTalk", "$env:LOCALAPPDATA\DingTalk") }
    @{ Name='企业微信残留';      Roots=@("$env:APPDATA\Tencent\WXWork") }
    @{ Name='各类Updater残留';   Roots=@("$env:LOCALAPPDATA\Updater", "$env:LOCALAPPDATA\Update") }
    @{ Name='搜狗输入法残留';    Roots=@("$env:APPDATA\SogouInput", "$env:LOCALAPPDATA\SogouInput") }
    @{ Name='WPS旧版缓存';       Roots=@("$env:LOCALAPPDATA\Kingsoft\WPS\addons", "$env:APPDATA\kingsoft\office6\backup") }
    @{ Name='迅雷残留';          Roots=@("$env:APPDATA\Thunder Network", "$env:LOCALAPPDATA\Thunder Network") }
    @{ Name='百度网盘缓存残留';  Roots=@("$env:APPDATA\baidu\BaiduNetdisk", "$env:LOCALAPPDATA\baidu") }
)

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    } catch { return 0 }
}

function Test-Protected {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $p = $Path.TrimEnd('\').ToLower()
    foreach ($prot in $Global:ProtectedPaths) {
        if ($p -eq $prot -or $p.StartsWith($prot + '\')) { return $true }
    }
    return $false
}

function Get-RunningProcessDirs {
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    try {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $path = $_.Path
                if ($path) {
                    [void]$dirs.Add(([System.IO.Path]::GetDirectoryName($path)).ToLower())
                }
            } catch {}
        }
    } catch {}
    return $dirs
}

function Scan-TempFiles {
    $paths = @($env:TEMP, "$env:SystemRoot\Temp", "$env:SystemRoot\Prefetch") |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $size = 0
    foreach ($p in $paths) { $size += Get-FolderSize $p }
    return @{ Key='temp'; Name='系统/用户临时文件'; Size=$size; Paths=$paths; Risk='低'; Mode='content'; Detail='%TEMP%, Windows\Temp, Prefetch'; Checked=$true }
}

function Scan-RecycleBin {
    $size = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $rb = $shell.NameSpace(0x0a)
        if ($rb) { foreach ($item in $rb.Items()) { try { $size += $item.Size } catch {} } }
    } catch {}
    return @{ Key='recyclebin'; Name='回收站'; Size=$size; Paths=@(); Risk='低'; Mode='recyclebin'; Detail='清空所有磁盘的回收站'; Checked=$true }
}

function Scan-BrowserCache {
    $cachePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
    )
    $ffRoot = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ffRoot) {
        Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $cachePaths += (Join-Path $_.FullName 'cache2')
        }
    }
    $paths = $cachePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
    $size = 0
    foreach ($p in $paths) { $size += Get-FolderSize $p }
    return @{ Key='browser'; Name='浏览器缓存(Chrome/Edge/Firefox)'; Size=$size; Paths=$paths; Risk='低'; Mode='content'; Detail='仅清缓存, 不动密码/书签/历史'; Checked=$true }
}

function Scan-WindowsUpdate {
    $paths = @("$env:SystemRoot\SoftwareDistribution\Download", "$env:SystemRoot\Logs\CBS") |
             Where-Object { Test-Path -LiteralPath $_ }
    $size = 0
    foreach ($p in $paths) { $size += Get-FolderSize $p }
    return @{ Key='winupdate'; Name='Windows更新缓存/日志'; Size=$size; Paths=$paths; Risk='中'; Mode='content'; Detail='更新下载缓存与CBS日志(默认不勾选)'; Checked=$false }
}

function Scan-BigLogs {
    param([double]$ThresholdMB = 50)
    $threshold = $ThresholdMB * 1MB
    $searchRoots = @(
        "$env:LOCALAPPDATA",
        "$env:APPDATA",
        "$env:ProgramData",
        "$env:SystemRoot\Logs"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
    $bigFiles = @()
    $size = 0
    foreach ($root in $searchRoots) {
        try {
            Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.log','*.etl','*.dmp' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $threshold -and -not (Test-Protected $_.DirectoryName) } |
            ForEach-Object {
                $bigFiles += $_.FullName
                $size += $_.Length
            }
        } catch {}
    }
    return @{ Key='biglogs'; Name="大日志文件(>$ThresholdMB MB)"; Size=$size; Paths=$bigFiles; Risk='中'; Mode='files'; Detail="$($bigFiles.Count) 个大日志/转储文件(默认不勾选)"; Checked=$false }
}

function Scan-Residual {
    param([int]$Days = 90)
    $cutoff = (Get-Date).AddDays(-$Days)
    $running = Get-RunningProcessDirs
    $found = @()
    $totalSize = 0
    foreach ($target in $Global:ResidualTargets) {
        foreach ($root in $target.Roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            try {
                $item = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
                if (-not $item) { continue }
                $last = $item.LastWriteTime
                if ($last -gt $cutoff) { continue }
                if ($running.Contains($root.ToLower())) { continue }
                $sz = Get-FolderSize $root
                if ($sz -le 0) { continue }
                $found += @{ Name=$target.Name; Path=$root; Size=$sz; LastWrite=$last }
                $totalSize += $sz
            } catch {}
        }
    }
    $paths = $found | ForEach-Object { $_.Path }
    $detailLines = $found | ForEach-Object { "  $($_.Name)  |  $(Format-Size $_.Size)  |  最后修改 $($_.LastWrite.ToString('yyyy-MM-dd'))  |  $($_.Path)" }
    $detail = if ($found.Count -gt 0) { ($detailLines -join "`n") } else { '未发现疑似残留' }
    return @{ Key='residual'; Name="应用残留(>$Days 天未用)"; Size=$totalSize; Paths=@($paths); Risk='高'; Mode='folder'; Detail=$detail; Checked=$false; Items=$found }
}

function Scan-BigFolders {
    $roots = @("C:\", "C:\Users") | Select-Object -Unique
    $results = @()
    foreach ($root in $roots) {
        try {
            Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Protected $_.FullName) } |
            ForEach-Object {
                $sz = Get-FolderSize $_.FullName
                if ($sz -gt 0) {
                    $results += @{ Path=$_.FullName; Size=$sz }
                }
            }
        } catch {}
    }
    return @($results | Sort-Object Size -Descending | Select-Object -First 10)
}
'@

# 全局后台任务状态
$Global:PendingTasks  = @{}       # 正在执行的后台任务 (键 → @{ PS; Handle; Desc })
$Global:TotalFreeable = 0

# ============================================================
#  删除执行 (分级: 低风险永久删, 高风险移回收站)
#  返回: @{ Freed; Deleted(数组); Skipped(数组) }
# ============================================================

# 移入回收站 (单文件/文件夹)
function Move-ToRecycleBin {
    param([string]$Path)
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
        return $true
    } catch { return $false }
}

# ============================================================
#  XAML 界面
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="C盘清理工具" Height="640" Width="820"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E2E"
        FontFamily="Microsoft YaHei UI" ResizeMode="CanMinimize">
    <Window.Resources>
        <!-- ListView 深色主题: 覆盖默认白色背景 -->
        <Style x:Key="DarkListViewItem" TargetType="ListViewItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF3A3A4C"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="Padding" Value="4,6"/>
            <!-- 禁用默认焦点矩形(蓝白虚框) -->
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <!-- 关键: GridViewRowPresenter 是 GridView 必须的渲染器 -->
            <!-- 如果写成 ContentPresenter，WPF 忽略所有列绑定，回退到 ToString() -->
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListViewItem">
                        <Border Name="Bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <GridViewRowPresenter
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <!-- 鼠标悬停: 浅灰蓝背景 -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#FF35354D"/>
                            </Trigger>
                            <!-- 选中行: 通常状态 (蓝色背景 + 白色文字) -->
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#FF4EA1FF"/>
                                <Setter Property="Foreground" Value="White"/>
                                <Setter Property="TextElement.Foreground" Value="White"/>
                            </Trigger>
                            <!-- 选中但窗口失去焦点: 深灰背景 + 浅灰文字 (看得见, 不刺眼) -->
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsSelected" Value="True"/>
                                    <Condition Property="Selector.IsSelectionActive" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="Bd" Property="Background" Value="#FF3A3A5C"/>
                                <Setter Property="Foreground" Value="#FFD0D0E0"/>
                                <Setter Property="TextElement.Foreground" Value="#FFD0D0E0"/>
                            </MultiTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- GridView 表头深色主题 -->
        <Style TargetType="GridViewColumnHeader">
            <Setter Property="Background" Value="#FF252537"/>
            <Setter Property="Foreground" Value="#FFB0B0C0"/>
            <Setter Property="BorderBrush" Value="#FF3A3A4C"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GridViewColumnHeader">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Left"
                                              VerticalAlignment="Center"
                                              Content="{TemplateBinding Content}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- CheckBox 深色主题: 自动继承父级前景色, 选中时也保证可见 -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{Binding RelativeSource={RelativeSource FindAncestor, AncestorType={x:Type ListViewItem}}, Path=TextElement.Foreground}"/>
            <Setter Property="Background" Value="#FF2A2A3C"/>
            <Setter Property="BorderBrush" Value="#FF4EA1FF"/>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- 标题与磁盘总览 -->
        <StackPanel Grid.Row="0">
            <TextBlock Text="C盘清理工具" Foreground="White" FontSize="22" FontWeight="Bold"/>
            <TextBlock x:Name="DiskInfo" Text="正在读取磁盘信息..." Foreground="#FFB0B0C0" FontSize="13" Margin="0,6,0,4"/>
            <ProgressBar x:Name="DiskBar" Height="10" Minimum="0" Maximum="100" Value="0"
                         Foreground="#FF4EA1FF" Background="#FF2A2A3C" BorderThickness="0"/>
        </StackPanel>

        <!-- 工具栏 -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,8">
            <Button x:Name="BtnScan" Content="开始扫描" Width="110" Height="34" Margin="0,0,8,0"
                    Background="#FF4EA1FF" Foreground="White" BorderThickness="1" BorderBrush="#FF77BBFF" Cursor="Hand"/>
            <Button x:Name="BtnBigFolder" Content="扫描大文件夹Top10" Width="160" Height="34" Margin="0,0,8,0"
                    Background="#FF6C5CE7" Foreground="White" BorderThickness="1" BorderBrush="#FF9988FF" Cursor="Hand"/>
            <TextBlock Text="残留阈值(天):" Foreground="#FFB0B0C0" VerticalAlignment="Center" Margin="6,0,4,0"/>
            <TextBox x:Name="TxtDays" Text="90" Width="50" Height="28" VerticalContentAlignment="Center"
                     Background="#FF2A2A3C" Foreground="White" BorderThickness="0"/>
            <TextBlock Text="  大日志阈值(MB):" Foreground="#FFB0B0C0" VerticalAlignment="Center" Margin="6,0,4,0"/>
            <TextBox x:Name="TxtLogMB" Text="50" Width="50" Height="28" VerticalContentAlignment="Center"
                     Background="#FF2A2A3C" Foreground="White" BorderThickness="0"/>
        </StackPanel>

        <!-- 清理项列表 -->
        <Border Grid.Row="2" Background="#FF252537" CornerRadius="6" Padding="4">
            <ListView x:Name="ItemList" Background="Transparent" BorderThickness="0" Foreground="White"
                      ItemContainerStyle="{StaticResource DarkListViewItem}">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="" Width="40">
                            <GridViewColumn.CellTemplate>
                                <DataTemplate>
                                    <CheckBox IsChecked="{Binding Checked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                              HorizontalAlignment="Center" VerticalAlignment="Center"
                                              Width="18" Height="18" Margin="2,0"/>
                                </DataTemplate>
                            </GridViewColumn.CellTemplate>
                        </GridViewColumn>
                        <GridViewColumn Header="清理项" Width="260" DisplayMemberBinding="{Binding Name}"/>
                        <GridViewColumn Header="可释放" Width="100" DisplayMemberBinding="{Binding SizeText}"/>
                        <GridViewColumn Header="风险" Width="60" DisplayMemberBinding="{Binding Risk}"/>
                        <GridViewColumn Header="说明" Width="240" DisplayMemberBinding="{Binding Detail}"/>
                    </GridView>
                </ListView.View>
            </ListView>
        </Border>

        <!-- 状态与进度 -->
        <StackPanel Grid.Row="3" Margin="0,10,0,0">
            <ProgressBar x:Name="ProgBar" Height="8" Minimum="0" Maximum="100" Value="0"
                         Foreground="#FF00D68F" Background="#FF2A2A3C" BorderThickness="0"/>
            <TextBlock x:Name="StatusText" Text="就绪。点击 [开始扫描] 计算可释放空间。" Foreground="#FFB0B0C0" FontSize="12" Margin="0,6,0,0"/>
        </StackPanel>

        <!-- 操作按钮 -->
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnSelectAll" Content="全选低风险" Width="110" Height="36" Margin="0,0,8,0"
                    Background="#FF55557A" Foreground="White" BorderThickness="1" BorderBrush="#FF7777AA" Cursor="Hand"/>
            <Button x:Name="BtnClean" Content="清理选中项" Width="140" Height="36"
                    Background="#FF00B894" Foreground="White" BorderThickness="1" BorderBrush="#FF33DDA0" FontWeight="Bold" Cursor="Hand"/>
        </StackPanel>
    </Grid>
</Window>
"@

# ---------- 构建窗口 ----------
try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("界面加载失败:`n$($_.Exception.Message)", "错误", 'OK', 'Error')
    exit 1
}

# 取控件
$DiskInfo    = $window.FindName('DiskInfo')
$DiskBar     = $window.FindName('DiskBar')
$BtnScan     = $window.FindName('BtnScan')
$BtnBigFolder= $window.FindName('BtnBigFolder')
$TxtDays     = $window.FindName('TxtDays')
$TxtLogMB    = $window.FindName('TxtLogMB')
$ItemList    = $window.FindName('ItemList')
$ProgBar     = $window.FindName('ProgBar')
$StatusText  = $window.FindName('StatusText')
$BtnSelectAll= $window.FindName('BtnSelectAll')
$BtnClean    = $window.FindName('BtnClean')

# 全局存放扫描得到的原始项 (含 Paths/Mode 等)
$Global:ScanData = @{}
$Global:UIItems  = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ItemList.ItemsSource = $Global:UIItems

# ---------- UI 辅助 ----------
function Set-Status {
    param([string]$Text)
    # 容错: $window 为 $null 时直接写入日志，避免提前调用导致闪退
    if ($null -eq $window -or $null -eq $StatusText) {
        Write-Log "Set-Status (窗口未就绪): $Text"
        return
    }
    try {
        # 用闭包捕获 $Text，避免 [action] 无参委托传参不匹配
        $captured = $Text
        $null = $window.Dispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [action]{ if ($null -ne $StatusText) { $StatusText.Text = $captured } }
        )
    } catch {
        Write-Log "Set-Status 异常: $($_.Exception.Message)"
    }
}

function Update-DiskInfo {
    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $used = $drive.Used; $free = $drive.Free; $total = $used + $free
        $pct = if ($total -gt 0) { [math]::Round($used / $total * 100, 1) } else { 0 }
        $DiskInfo.Text = "C盘  总容量 $(Format-Size $total)   已用 $(Format-Size $used)   可用 $(Format-Size $free)   ($pct%)"
        $DiskBar.Value = $pct
    } catch {
        $DiskInfo.Text = "无法读取C盘信息: $($_.Exception.Message)"
    }
}

# 把扫描结果项加入 UI 列表
function Add-UIItem {
    param($Scan)
    $obj = [pscustomobject]@{
        Key      = $Scan.Key
        Name     = $Scan.Name
        SizeText = Format-Size $Scan.Size
        Risk     = $Scan.Risk
        Detail   = ($Scan.Detail -split "`n")[0]
        Checked  = [bool]$Scan.Checked
    }
    $Global:ScanData[$Scan.Key] = $Scan
    $Global:UIItems.Add($obj)
}

Update-DiskInfo

# ============================================================
#  扫描 — 后台 Runspace 异步并行 (不卡 UI)
#  启动 6 个后台任务, DispatcherTimer 轮询完成结果
# ============================================================
$Global:Busy = $false

function Invoke-Scan {
    if ($Global:Busy) { return }
    $Global:Busy = $true
    $BtnScan.IsEnabled = $false; $BtnClean.IsEnabled = $false; $BtnBigFolder.IsEnabled = $false
    $Global:UIItems.Clear(); $Global:ScanData.Clear()
    $Global:PendingTasks.Clear()
    $Global:TotalFreeable = 0
    $ProgBar.Value = 0
    Set-Status "正在启动扫描任务..."

    $days  = 90; [int]::TryParse($TxtDays.Text, [ref]$days)  | Out-Null
    $logMB = 50; [int]::TryParse($TxtLogMB.Text, [ref]$logMB) | Out-Null

    # 定义 6 个并行任务 (每个在自己的 PowerShell 实例中)
    $taskDefs = @(
        @{ Key='temp';      Desc='临时文件';      Script="Scan-TempFiles" }
        @{ Key='recyclebin';Desc='回收站';        Script="Scan-RecycleBin" }
        @{ Key='browser';   Desc='浏览器缓存';    Script="Scan-BrowserCache" }
        @{ Key='winupdate'; Desc='Windows更新';   Script="Scan-WindowsUpdate" }
        @{ Key='biglogs';   Desc='大日志文件';    Script="Scan-BigLogs -ThresholdMB $logMB" }
        @{ Key='residual';  Desc='应用残留';      Script="Scan-Residual -Days $days" }
    )

    $Global:PendingTaskCount = $taskDefs.Count

    foreach ($def in $taskDefs) {
        # 每个任务创建独立的 Runspace（Runspace 一次只能跑一个 pipeline，必须独立）
        $rs = [RunspaceFactory]::CreateRunspace()
        $rs.Open()
        # 加载 init 脚本到该 Runspace
        $psInit = [PowerShell]::Create()
        $psInit.Runspace = $rs
        $null = $psInit.AddScript($initScript)
        $null = $psInit.Invoke()
        $psInit.Dispose()
        # 启动任务
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($def.Script)
        $handle = $ps.BeginInvoke()
        $Global:PendingTasks[$def.Key] = @{ PS=$ps; Handle=$handle; Desc=$def.Desc; Runspace=$rs }
    }

    Set-Status "正在后台扫描 ($($taskDefs.Count) 项并行)... 界面保持响应。"

    # 创建并启动轮询计时器 (DispatcherTimer 回调在 UI 线程上执行)
    if ($Global:PollTimer) { try { $Global:PollTimer.Stop() } catch {} }
    $Global:PollTimer = New-Object Windows.Threading.DispatcherTimer
    $Global:PollTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Global:PollTimer.Add_Tick({
        # 遍历所有任务, 处理已完成的
        foreach ($key in @($Global:PendingTasks.Keys)) {
            $task = $Global:PendingTasks[$key]
            if (-not $task) { continue }
            if ($task.Handle.IsCompleted) {
                try {
                    $result = $task.PS.EndInvoke($task.Handle)
                    if ($result -and $result.Count -gt 0 -and $result[0]) {
                        # 在主脚本添加 UI 项 (Timer 在 UI 线程, 直接调用)
                        $obj = [pscustomobject]@{
                            Key      = $result[0].Key
                            Name     = $result[0].Name
                            SizeText = Format-Size $result[0].Size
                            Risk     = $result[0].Risk
                            Detail   = ($result[0].Detail -split "`n")[0]
                            Checked  = [bool]$result[0].Checked
                        }
                        $Global:ScanData[$result[0].Key] = $result[0]
                        $Global:UIItems.Add($obj)
                        $Global:TotalFreeable += [double]$result[0].Size
                    }
                } catch {
                    Write-Log "后台任务 $key 取结果失败: $($_.Exception.Message)"
                } finally {
                    $task.PS.Dispose()
                    try { $task.Runspace.Dispose() } catch {}
                }
                # 从 PendingTasks 移除 (允许重新扫描)
                $null = $Global:PendingTasks.Remove($key)
            }
        }

        # 进度 — 只用全局变量 (避免 Invoke-Scan 返回后局部变量消失)
        $completedCount = $Global:PendingTaskCount - $Global:PendingTasks.Count
        $pct = if ($Global:PendingTaskCount -gt 0) { [math]::Min(99, [math]::Round($completedCount / $Global:PendingTaskCount * 100, 1)) } else { 0 }
        $ProgBar.Value = $pct

        # 全部完成?
        if ($Global:PendingTasks.Count -eq 0 -and $Global:PendingTaskCount -gt 0) {
            $Global:PollTimer.Stop()
            Set-Status "扫描完成。共发现可释放约 $(Format-Size $Global:TotalFreeable)。请勾选后点击 [清理选中项]。"
            $ProgBar.Value = 100
            $BtnScan.IsEnabled = $true; $BtnClean.IsEnabled = $true; $BtnBigFolder.IsEnabled = $true
            $Global:Busy = $false
        }
    })
    $Global:PollTimer.Start()
}

# ============================================================
#  清理执行
# ============================================================
function Invoke-Clean {
    if ($Global:Busy) { return }

    # 收集勾选项
    $selected = @($Global:UIItems | Where-Object { $_.Checked })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("请先勾选要清理的项目。", "提示", 'OK', 'Information') | Out-Null
        return
    }

    # 高风险项二次确认 (列出路径/大小/时间)
    $highRisk = @($selected | Where-Object { $Global:ScanData[$_.Key].Risk -eq '高' })
    if ($highRisk.Count -gt 0) {
        $msg = "以下为【高风险】项目, 将被移入回收站(可恢复)。请确认:`n`n"
        foreach ($h in $highRisk) {
            $sc = $Global:ScanData[$h.Key]
            $msg += "● $($sc.Name)  共 $(Format-Size $sc.Size)`n"
            if ($sc.Items) {
                foreach ($it in $sc.Items) {
                    $msg += "    - $($it.Name)  $(Format-Size $it.Size)  改于$($it.LastWrite.ToString('yyyy-MM-dd'))`n      $($it.Path)`n"
                }
            }
        }
        $msg += "`n是否继续?"
        $r = [System.Windows.MessageBox]::Show($msg, "高风险确认", 'YesNo', 'Warning')
        if ($r -ne 'Yes') { Set-Status "已取消清理。"; return }
    }

    $Global:Busy = $true
    $BtnScan.IsEnabled = $false; $BtnClean.IsEnabled = $false
    $ProgBar.Value = 0

    $beforeFree = (Get-PSDrive -Name C).Free
    $deleted = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    $total = $selected.Count; $idx = 0
    foreach ($sel in $selected) {
        $idx++
        $sc = $Global:ScanData[$sel.Key]
        Set-Status "正在清理: $($sc.Name) ... ($idx/$total)"
        $ProgBar.Value = [math]::Round($idx / $total * 100)
        # 触发UI消息泵，让界面刷新
        $null = $window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]{})

        try {
            switch ($sc.Mode) {
                'recyclebin' {
                    try { Clear-RecycleBin -Force -ErrorAction Stop; $deleted.Add('回收站已清空') | Out-Null }
                    catch { $skipped.Add("回收站: $($_.Exception.Message)") | Out-Null }
                }
                'content' {
                    # 删除目录内的内容, 保留目录本身
                    foreach ($p in $sc.Paths) {
                        if (-not (Test-SafeToDelete $p)) { $skipped.Add("$p (安全保护跳过)") | Out-Null; continue }
                        Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                            try {
                                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                                $deleted.Add($_.FullName) | Out-Null
                            } catch {
                                $skipped.Add("$($_.FullName) (占用或无权限)") | Out-Null
                            }
                        }
                    }
                }
                'files' {
                    foreach ($f in $sc.Paths) {
                        try {
                            Remove-Item -LiteralPath $f -Force -ErrorAction Stop
                            $deleted.Add($f) | Out-Null
                        } catch { $skipped.Add("$f (占用或无权限)") | Out-Null }
                    }
                }
                'folder' {
                    # 高风险: 移入回收站
                    foreach ($p in $sc.Paths) {
                        if (-not (Test-SafeToDelete $p)) { $skipped.Add("$p (安全保护跳过)") | Out-Null; continue }
                        if (Move-ToRecycleBin $p) { $deleted.Add("$p -> 回收站") | Out-Null }
                        else { $skipped.Add("$p (移动失败/被占用)") | Out-Null }
                    }
                }
            }
        } catch {
            $skipped.Add("$($sc.Name): $($_.Exception.Message)") | Out-Null
        }
    }

    Start-Sleep -Milliseconds 300
    $afterFree = (Get-PSDrive -Name C).Free
    $freed = $afterFree - $beforeFree
    if ($freed -lt 0) { $freed = 0 }

    $ProgBar.Value = 100
    Update-DiskInfo
    Set-Status "清理完成。释放约 $(Format-Size $freed)。删除 $($deleted.Count) 项, 跳过 $($skipped.Count) 项。"

    # ---------- 完成报告弹框 (不自动关闭) ----------
    $report  = "✅ 清理完成`n`n"
    $report += "释放空间: $(Format-Size $freed)`n"
    $report += "成功删除: $($deleted.Count) 项`n"
    $report += "安全跳过: $($skipped.Count) 项`n`n"
    if ($skipped.Count -gt 0) {
        $report += "【已跳过 - 安全保护或被占用】(最多显示10条):`n"
        $report += (($skipped | Select-Object -First 10) -join "`n")
        if ($skipped.Count -gt 10) { $report += "`n... 其余 $($skipped.Count - 10) 项" }
    }
    [System.Windows.MessageBox]::Show($report, "清理完成", 'OK', 'Information') | Out-Null

    $BtnScan.IsEnabled = $true; $BtnClean.IsEnabled = $true
    $Global:Busy = $false
}

# ============================================================
#  大文件夹 Top10
# ============================================================
function Invoke-BigFolder {
    if ($Global:Busy) { return }
    $Global:Busy = $true
    $BtnScan.IsEnabled = $false; $BtnClean.IsEnabled = $false; $BtnBigFolder.IsEnabled = $false
    Set-Status "正在后台扫描 C盘 大文件夹 Top10..."

    # 创建独立的 Runspace（避免与扫描任务冲突）
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.Open()
    # 加载 init 脚本
    $psInit = [PowerShell]::Create()
    $psInit.Runspace = $rs
    $null = $psInit.AddScript($initScript)
    $null = $psInit.Invoke()
    $psInit.Dispose()

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript("Scan-BigFolders")
    $handle = $ps.BeginInvoke()

    # 单任务轮询计时器
    if ($Global:BigFolderTimer) { try { $Global:BigFolderTimer.Stop() } catch {} }
    $Global:BigFolderTimer = New-Object Windows.Threading.DispatcherTimer
    $Global:BigFolderTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $Global:BigFolderTimer.Add_Tick({
        if ($handle.IsCompleted) {
            $Global:BigFolderTimer.Stop()
            try {
                $result = $ps.EndInvoke($handle)
                if ($result -and $result.Count -gt 0) {
                    $top = $result[0]
                    $msg = "C盘占用空间最大的文件夹 Top10:`n`n"
                    $rank = 0
                    foreach ($t in $top) {
                        $rank++
                        $msg += ("{0,2}. {1,-10}  {2}`n" -f $rank, (Format-Size $t.Size), $t.Path)
                    }
                    $msg += "`n提示: 此为只读分析, 请自行判断后手动处理。"
                    [System.Windows.MessageBox]::Show($msg, "大文件夹 Top10", 'OK', 'Information') | Out-Null
                    Set-Status "大文件夹扫描完成。"
                } else {
                    Set-Status "大文件夹扫描结果为空。"
                }
            } catch {
                Set-Status "大文件夹扫描出错: $($_.Exception.Message)"
                Write-Log "BigFolder 后台任务异常: $($_.Exception.Message)"
            } finally {
                $ps.Dispose()
                try { $rs.Dispose() } catch {}
            }
            $BtnScan.IsEnabled = $true; $BtnClean.IsEnabled = $true; $BtnBigFolder.IsEnabled = $true
            $Global:Busy = $false
        }
    })
    $Global:BigFolderTimer.Start()
}

# ============================================================
#  事件绑定
# ============================================================
$BtnScan.Add_Click({ Invoke-Scan })
$BtnClean.Add_Click({ Invoke-Clean })
$BtnBigFolder.Add_Click({ Invoke-BigFolder })
$BtnSelectAll.Add_Click({
    foreach ($it in $Global:UIItems) {
        if ($Global:ScanData[$it.Key].Risk -eq '低') { $it.Checked = $true }
    }
    $ItemList.Items.Refresh()
})

# CheckBox 点击兜底：PSObject 的 WPF 双向绑定时有不生效，
# 在 ListView 级别捕获 CheckBox Click，同步数据到控件视觉状态
$ItemList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $cb = $e.OriginalSource
    if ($cb -is [System.Windows.Controls.Primitives.ToggleButton]) {
        $item = $cb.DataContext
        if ($item -and $null -ne $item.Checked) {
            $item.Checked = ($cb.IsChecked -eq $true)
        }
    }
})

# 需要 WinForms 的 DoEvents/MessageBox 兜底
try { Add-Type -AssemblyName System.Windows.Forms } catch {}

# 窗口渲染完成后自动扫描一次 (异步后台, 不卡 UI)
$window.Add_ContentRendered({
    try {
        Invoke-Scan
    } catch {
        Write-Log "自动扫描异常: $($_.Exception.Message)"
        Set-Status "扫描出错: $($_.Exception.Message) (日志见: $Global:LogFile)"
    }
})

# ---------- 全局兜底: UI 线程未捕获异常 ----------
# 截获任何漏网的 UI 线程异常, 写日志并在状态栏提示, 标记 Handled 阻止进程崩溃,
# 避免再次出现"窗口闪退无痕迹"。
try {
    $window.Dispatcher.Add_UnhandledException({
        param($sender, $e)
        try {
            Write-Log "UI未捕获异常: $($e.Exception.Message)`n$($e.Exception.StackTrace)"
            $StatusText.Text = "发生错误(已记录日志, 程序继续): $($e.Exception.Message)"
        } catch {}
        $e.Handled = $true
    })
} catch { Write-Log "注册全局异常handler失败: $($_.Exception.Message)" }

# 窗口关闭时清理后台资源
$window.Add_Closed({
    try {
        if ($Global:PollTimer) { $Global:PollTimer.Stop() }
        if ($Global:BigFolderTimer) { $Global:BigFolderTimer.Stop() }
        # Dispose 所有未完成的后台任务 (含 Runspace)
        foreach ($entry in $Global:PendingTasks.Values) {
            try { $entry.PS.Dispose() } catch {}
            try { $entry.Runspace.Dispose() } catch {}
        }
        $Global:PendingTasks.Clear()
    } catch { Write-Log "窗口关闭清理异常: $($_.Exception.Message)" }
})

# 显示窗口
try {
    [void]$window.ShowDialog()
} catch {
    Write-Log "ShowDialog异常: $($_.Exception.Message)"
    try {
        [System.Windows.MessageBox]::Show("程序启动失败:`n$($_.Exception.Message)`n`n日志: $Global:LogFile", "错误", 'OK', 'Error') | Out-Null
    } catch {}
}
