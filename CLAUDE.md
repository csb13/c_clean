# C盘清理工具 (CClean)

## 项目概况

一个开箱即用的 C盘清理工具，零安装，依赖 Win10/11 自带的 PowerShell 5.1 + WPF。整个文件夹拷到任意电脑，双击即可运行，会自动申请管理员权限。

## 项目位置

```
c_clear\CClean\一键清理C盘.bat   — 启动器，双击运行，自动提权
c_clear\CClean\CClean.ps1        — 主程序（WPF 界面 + 扫描 + 分级清理）
c_clear\CClean\README.txt           — 使用说明
```

## 架构概览

### 当前架构（第三版 · 2026-06 重构）

```
┌─ UI 线程 (WPF Dispatcher) ─────────────────────────────┐
│                                                          │
│  双击 BAT → PowerShell -STA -File CClean.ps1             │
│       ↓                                                  │
│  ContentRendered → Invoke-Scan (瞬间返回)                │
│       ↓                                                  │
│  [PowerShell]::Create() × 6 → BeginInvoke()             │
│       ↓                                                  │
│  DispatcherTimer (300ms) → 轮询 IsCompleted               │
│       ↓                                                  │
│  EndInvoke → 取结果 → Add-UIItem → 逐条显示               │
│                                                          │
└──────────────────────────────────────────────────────────┘
        │                              ▲
        │ 6 个并行任务                   │ UI 线程更新
        ▼                              │
┌─ 后台 Runspace ─────────────────────────────────────────┐
│                                                          │
│  [RunspaceFactory]::CreateRunspace()                     │
│      ↓                                                   │
│  initScript 预加载:                                      │
│    · 全局变量 (SafeRoots, ProtectedPaths, ResidualTargets)│
│    · 辅助函数 (Format-Size, Get-FolderSize, Test-Protected)│
│    · 7 个扫描函数 (TempFiles ~ BigFolders)               │
│      ↓                                                   │
│  6 个 PowerShell 实例并行执行扫描                         │
│  (各自独立, 互不阻塞)                                     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 关键设计决策

| 决策 | 方案 | 理由 |
|------|------|------|
| 后台执行 | Runspace + BeginInvoke | 裸 ThreadPool 无 DefaultRunspace 会崩 |
| 结果回传 | DispatcherTimer 轮询 | 比 AsyncCallback 安全，避免跨线程死锁 |
| 函数定义 | initScript 预加载到 Runspace | 解决 Runspace 隔离问题 |
| 扫描顺序 | 6 项并行 | 互不依赖，并行更快 |
| 进度条 | 完成项数 / 总项数 | 简单可靠 |
| UI 更新 | Timer 在 UI 线程直接更新 | DispatcherTimer 回调天生在 UI 线程 |

## 已实现能力

### 核心功能

- **扫描预览后再清**：打开自动扫描，列出每项可释放大小 → 勾选 → 清理
- **清理项（按风险分级）**：
  - **低风险**：临时文件、回收站、浏览器缓存（不碰密码/书签）
  - **中风险**：Windows 更新缓存/日志、大日志文件（默认不勾选）
  - **高风险**：应用残留智能识别
- **应用残留分析**：内置 360/钉钉/迅雷/搜狗/WPS 等易残留软件白名单，不盲删 AppData；LastWriteTime 时间戳判断（默认 90 天，界面可调）；运行进程检测，正在运行的不算残留
- **大文件夹 Top10**：只读分析 C盘 占用最大目录，不自动删

### 安全机制

- 安全白名单：绝不碰系统关键目录（System32 / WinSxS / Program Files 等）
- 被占用/无权限的文件自动跳过，不中断流程
- 高风险项移入回收站（可恢复），而非永久删除
- 清理前先扫描预览，由勾选确认后才执行

## 问题解决历史

### 第三版：后台 Runspace 异步扫描，彻底解决界面卡死 (2026-06-13)

#### 现象
工具启动后或点击按钮后界面无响应，无法操作。

#### 根因
同步扫描在 UI 线程上执行 `Get-ChildItem -Recurse`（递归遍历文件系统），每次耗时 10~60 秒占死 UI 线程。`Invoke-DoEvents` 消息泵只在 6 个扫描步骤之间调用，中间这段时间 WPF 无法处理任何输入/绘制消息，用户感觉\"死机\"。

**关键教训**：`DispatcherFrame` + `PushFrame`（DoEvents）无法解决长耗时的 I/O 阻塞问题。正确的做法是把 I/O 操作移到真正的后台线程（且线程必须有 PowerShell Runspace）。

#### 解决方案

1. **Runspace 后台执行**：创建全局 `[RunspaceFactory]::CreateRunspace()`，所有扫描在其上并行执行。
2. **initScript 预加载**：将全局变量（`SafeRoots`、`ProtectedPaths`、`ResidualTargets`）和 7 个扫描函数定义加载到 Runspace 中，解决跨 Runspace 函数不可见问题。
3. **DispatcherTimer 轮询**：每 300ms 检查后台任务完成状态，完成后在 UI 线程直接更新 ListView。
4. **移除 Invoke-DoEvents**：不再需要消息泵 hack。
5. **窗口关闭清理**：`Add_Closed` 中 Dispose 未完成任务、停止 Timer、关闭 Runspace。

#### 验证
- 全文件 AST 解析：`PARSE OK - no syntax errors`。
- 扫描期间界面可点击、可拖动、进度条平滑更新。
- 6 项扫描并行执行，总耗时≈最慢项耗时。

---

### 第二版：DoEvents 消息泵修复闪退 (2026-06 上旬)

#### 现象
双击启动后，WPF 窗口闪一下消失，只剩 BAT 的控制台窗口，且控制台**无任何报错输出**。

#### 真正的根因：裸 .NET 线程上执行 PowerShell 脚本块 → 进程级崩溃

`ContentRendered` 处理器把 6 个 `Scan-*` **PowerShell 脚本块丢到裸 .NET 线程池**（`[System.Threading.ThreadPool]::QueueUserWorkItem`）上执行。这是 PowerShell + WPF 的致命坑：

- PowerShell 脚本块执行必须绑定一个 **Runspace**。裸 ThreadPool 线程上**没有 `DefaultRunspace`**，cmdlet 一执行就抛 *\"There is no Runspace available in this thread to run scripts\"*。
- 该异常位于 `try/catch` 之外 → 直接终结整个进程 → 窗口瞬间消失。

#### 第二版的解决（已被第三版取代）
1. `ContentRendered` 改回 UI 线程执行。
2. 新增 `Invoke-DoEvents` 消息泵（基于 `DispatcherFrame` + `PushFrame`）。
3. 恢复全局 `Dispatcher.Add_UnhandledException` 兜底。

---

### 第一版：早期闪退隐患 (历史背景)

> 以下是更早一轮排查时处理的隐患，保留备查。

#### 当时的技术隐患
1. **Measure-Object 对哈希表求和失败**：PowerShell 5.1 的 `Measure-Object -Property Size` 无法从哈希表读取 Size 键作为属性，抛错。
2. **$ErrorActionPreference = 'Stop'**：全局 Stop 导致任何未被逐处 try/catch 的错误都直接炸掉进程。
3. **Dispatcher.Invoke 使用字符串优先级**：`'Background'` 字符串而非 `[Windows.Threading.DispatcherPriority]::Background` 强类型，不稳定。
4. **ContentRendered 回调无 try/catch**：扫描中未预期错误直接传播到 UI 线程。

#### 当时的解决
1. 改为累加求和：扫描中直接累加每项大小，不再对哈希表用 Measure-Object。
2. $ErrorActionPreference 改为 'Continue'：改为逐处 try/catch。
3. Dispatcher.Invoke → BeginInvoke：非阻塞调用。
4. 强类型 DispatcherPriority：使用枚举而非字符串。
5. ContentRendered 加 try/catch。
6. 新增 Write-Log 日志函数。
7. BAT 文件增强错误提示。

## 用户需要做的

双击 `一键清理C盘.bat` 试一次。如果还有问题，查看 `CClean` 目录下 `CClean_*.log` 日志文件中的错误详情。
