# C盘清理工具 (CClean)

## 项目概况

一个开箱即用的 C盘清理工具，零安装，依赖 Win10/11 自带的 PowerShell 5.1 + WPF。整个文件夹拷到任意电脑，双击即可运行，会自动申请管理员权限。

## 项目位置

```
c_clear\CClean\一键清理C盘.bat   — 启动器，双击运行，自动提权
c_clear\CClean\CClean.ps1        — 主程序（WPF 界面 + 扫描 + 分级清理）
c_clear\CClean\README.txt           — 使用说明
```

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

## 问题解决（二）：窗口仍闪退，控制台保留但无输出 ← 当前根因

### 现象

双击启动后，WPF 窗口闪一下消失，只剩 BAT 的控制台窗口，且控制台**无任何报错输出**，`%TEMP%` 里也常常没有日志。

### 真正的根因：裸 .NET 线程上执行 PowerShell 脚本块 → 进程级崩溃

`ContentRendered` 处理器（自动扫描入口）把 6 个 `Scan-*` **PowerShell 脚本块丢到裸 .NET 线程池**（`[System.Threading.ThreadPool]::QueueUserWorkItem`）上执行。这是 PowerShell + WPF 的致命坑：

- PowerShell 脚本块执行必须绑定一个 **Runspace**。裸 ThreadPool 线程（以及 `New-Object System.Threading.Thread` 起的线程）上**没有 `DefaultRunspace`**，cmdlet 一执行就抛 *"There is no Runspace available in this thread to run scripts"*。
- 该异常发生在脚本块**被调用层**，位于你写的 `try/catch` 之外 → 线程池线程的未捕获异常按 .NET 规则**直接终结整个进程** → WPF 窗口瞬间消失。
- 控制台是 BAT 提权后新开的进程，主进程崩了所以**无任何输出**；崩溃在内层 try/catch 之外，所以连日志都写不出来。

**复现验证**：最小脚本在 ThreadPool 线程上跑任意 PS cmdlet，进程稳定以**退出码 2** 崩溃，内层 try/catch 捕获不到（日志文件都没写成）。

> 关键教训：**绝不能把 PowerShell 脚本块交给裸 .NET 线程（ThreadPool / new Thread）执行**。要后台跑 PS，必须用 PowerShell 自己的 Runspace/RunspacePool（`[PowerShell]::Create()` + `AddScript`），它会自带 Runspace。WPF 场景下最简单稳妥的做法是：扫描留在 UI 线程同步执行，用 DoEvents 消息泵保持界面响应。

### 解决方案（本轮）

1. **`ContentRendered` 改回 UI 线程执行**（根因修复）：删除裸线程池调用，改为以 `[Windows.Threading.DispatcherPriority]::ApplicationIdle` 在 UI 线程上调用已有的同步版 `Invoke-Scan`，整体包 try/catch 兜底。
2. **新增 `Invoke-DoEvents` 消息泵**：基于 `DispatcherFrame` + `[Dispatcher]::PushFrame`，在同步扫描的每步之间抽干一帧消息队列，界面保持刷新不假死——替代"丢后台线程防卡 UI"的危险做法。`Invoke-Scan` 循环内每步调用一次。
3. **恢复全局兜底 `Dispatcher.Add_UnhandledException`**：之前文档声称已加但代码里实际丢失。现注册到 window 的 Dispatcher，任何漏网的 UI 线程异常都写日志、状态栏提示、`$e.Handled = $true` 阻止进程崩溃，杜绝"无痕闪退"。
4. **`ShowDialog` 失败时弹 MessageBox** 并指向日志路径。

### 验证（本轮）

- 全文件 AST 解析：`PARSE OK - no syntax errors`。
- 实际启动窗口：自动扫描全程**稳定存活 20 秒未崩**（修复前为秒崩），`RESULT: PASS`。

---

## 问题解决（一）：早期闪退隐患（历史背景，已修）

> 以下是更早一轮排查时处理的隐患，与本轮根因不同，保留备查。

### 当时的技术隐患

1. **Measure-Object 对哈希表求和失败**：PowerShell 5.1 的 `Measure-Object -Property Size` 无法从哈希表读取 Size 键作为属性，抛错。
2. **$ErrorActionPreference = 'Stop'**：全局 Stop 导致任何未被逐处 try/catch 的错误都直接炸掉进程。
3. **Dispatcher.Invoke 使用字符串优先级**：`'Background'` 字符串而非 `[Windows.Threading.DispatcherPriority]::Background` 强类型，不稳定。
4. **ContentRendered 回调无 try/catch**：扫描中未预期错误直接传播到 UI 线程。

### 当时的解决

1. **改为累加求和**：扫描中直接累加每项大小，不再对哈希表用 Measure-Object。
2. **$ErrorActionPreference 改为 'Continue'**：改为逐处 try/catch。
3. **Dispatcher.Invoke → BeginInvoke**：非阻塞调用。
4. **强类型 DispatcherPriority**：使用枚举而非字符串。
5. **ContentRendered 加 try/catch**。
6. **新增 Write-Log 日志函数**：运行时错误写入 `%TEMP%\CClean_*.log`。
7. **BAT 文件增强错误提示**：失败时提示查看日志文件位置。

## 用户需要做的

双击 `一键清理C盘.bat` 试一次。如果还有问题，查看 `%TEMP%` 目录下 `CClean_*.log` 日志文件中的错误详情。
