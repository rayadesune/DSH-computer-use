# Windows 版本机验证记录

本文件记录 `dsh-ui.ps1`（Windows 版）在**真机**上的验证过程、结果，以及验证期间发现并修掉的问题。
目的有两个：证明它不是"看起来能用"，以及让后来的人能**复现**这份结论。

```powershell
# 复现（会短暂弹出一个自建的测试窗口，全程只操作它自己，不动你的其他窗口）
powershell -NoProfile -ExecutionPolicy Bypass -File tests\verify-windows.ps1 -AlsoPs51
```

结果文件：`tests/results-windows.json`。

## 环境

| 项 | 值 |
|---|---|
| OS | Windows 11（`Microsoft Windows NT 10.0.26200.0`） |
| 显示器 | 单屏 1920×1080，缩放 125%（DPI 120） |
| PowerShell 7 | 7.6.6 Core |
| Windows PowerShell | 5.1.26100.9444 Desktop |
| OCR 语言包 | `en-US`、`ja`、`zh-Hans-CN`（`OcrEngine.MaxImageDimension = 10000`） |
| 会话 | 交互式（Session 1，`UserInteractive = True`） |

## 验证方法

自动化套件 `tests/verify-windows.ps1` 的核心是**受控测试靶** `tests/ui-target.ps1`：
一个自建的 WinForms 窗口，把自身状态（文本框内容、按钮点击次数、拖拽起止点、列表滚动位置、
每个控件的屏幕矩形）以 150ms 周期写进 JSON 文件。

复现性上做了三件事：每次运行用**独立的随机状态文件**、启动前**清理上次中断残留的孤儿靶子进程**、
结束时杀靶子并还原光标与拦截名单。这样"上一次跑挂了"不会污染下一次的结论
（本项目确实踩过：孤儿靶子和新靶子抢写同一个状态文件，导致区域对不上、出现假失败）。

断言全部回到这份状态文件取证，而不是"看输出像不像成功"：

| 断言类型 | 取证方式 |
|---|---|
| 点击是否真的点到按钮 | 目标按钮的处理函数自增计数，比对增量 |
| 输入的字是否正确 | 比对文本框内容与请求字符串（含中文） |
| 拖拽落点是否准确 | 靶子报告 MouseDown/MouseUp 的控件内坐标，与请求位移比对（±3px） |
| 滚轮是否真的滚动 | 比对 ListBox 的 `TopIndex` 变化 |
| `--dry` 是否真的没执行 | 干跑前后点击计数必须不变 |
| 拦截名单是否真的拦住 | 临时把靶子加进名单，断言 exit=3 **且**计数不变，随后恢复名单 |
| OCR 定位精度 | OCR 命中的全局坐标必须落在该控件的真实矩形内 |
| 截图/网格 | 读 PNG 像素：尺寸、放大倍数、x=0 处红线、y=0 处蓝线 |

只读类命令（`shot`/`diff`/`find-text`/`find-ax`/`wait-for`/`under`/`displays`）在真实桌面上跑；
所有**会产生输入**的测试只打在自己启动的测试靶上，结束时杀掉靶子、把光标放回原位、恢复拦截名单。

## 结果

**44 项断言全部通过（FAIL 0 / SKIP 0）**，宿主覆盖 PowerShell 7 与 Windows PowerShell 5.1。

| 分组 | 覆盖的断言 |
|---|---|
| A. CLI 基线 | `--help` 覆盖全部已分发命令、`displays` 文本+JSON、`pos`、三类用法错误 exit=2、未命中 exit=1、审计日志逐条落盘、**`--dry` 矩阵（17 条输入类命令逐条比对 dry 行文案）** |
| B. 截图/像素 | `shot -R` 尺寸与映射一致、`--grid/--zoom` 派生文件与网格像素、`diff` 无差异、`wait-for --stable`、`wait-for --change`、`wait-for --text`（命中 + 超时 exit=1） |
| C. 定位 | `find-ax --pid`（含 pressable）、`find-ax --app` 按窗口标题匹配、`find-text` 命中坐标落在控件内、`under`、**`--dry` 预演一整套动作后靶子状态零变化** |
| D. 窗口 | `win list --json` 与 UIA 坐标一致、`win move` 回读、`win focus` 真的成为前台、`win maximize` 填满工作区 |
| E. 真实输入 | `click` 命中按钮、`--dry` 零副作用、`type` 中文+ASCII、`keys` 大小写与符号、`key ctrl+a`+`delete`、剪贴板粘贴、`drag` 位移、`scroll` 滚动列表、`find-ax --click`、`find-text --click`、拦截名单 exit=3 |
| F. 批量 | `batch` 从 stdin 逐条执行、注释跳过、逐条审计、`-c` 语义 |
| G. PS 5.1 宿主 | 同一批命令在 Windows PowerShell 5.1 下复跑（`--help`/`displays`/`pos`/`shot`/`diff`/`find-text`/`find-ax`/`win list`） |
| H. 安装/启动器 | `install.ps1` 安装后可运行、副本仍可解析、`-Uninstall` 清理干净、启动器原样透传退出码、`dsh-ui.cmd` 保持纯 ASCII、默认只装可执行文件（`-WithDocs` 才带文档）、`-SkillCopy` 复制模式的内容与 frontmatter、`-WithSkill` 联接模式下改仓库即生效且卸载只摘链接不动源目录、本机已装 skill 的漂移检测 |

`--dry` 是逐条比对**输出文案**的（`dry: would drag (10,10) -> (200,200) settle=80 hold=80 move=300 steps=12 momentum=0` 这种整行匹配），
再叠一层"预演 11 条动作后靶子的按钮计数 / 文本 / 拖拽标志 / 滚动位置 / 窗口位置 / 剪贴板全都没变"的副作用断言 ——
既证明它会打印，也证明它真的没执行。

### 关键实测数据

`find-text --click` 的定位精度（靶子按钮真实矩形 `141,318,110,34`，中心 `196,335`）：

```
OCR 命中 global = 197,334   clicked = 197,333      → 与按钮中心相差 1px，按钮计数 +1
```

单命令延迟（3 次平均，含进程启动）：

| 命令 | PowerShell 7 | Windows PowerShell 5.1 |
|---|---|---|
| `--help` | 983ms | 537ms |
| `pos` | 1028ms | 571ms |
| `shot -R 0,0,400,300` | 1243ms | 781ms |
| `find-ax` | 1094ms | 658ms |
| `find-text`（整屏 OCR） | 1798ms | **941ms** |
| `win list` | 1098ms | 702ms |

→ 5.1 快约一倍：WinRT OCR 可以在进程内直接调用，PS7 需要派生一个 5.1 子进程当 worker。

OCR 质量采样（同一屏，拉丁 vs 中文）：

| 屏幕上的文字 | OCR 结果 |
|---|---|
| `Submit` / `TARGET-ALPHA-9931` / `Windows (CRLF)` / `UTF-8` / `DeepSeek-H` | 完全正确 |
| `无标题 - Notepad` | `无 》 玺 题 - Notepad` |
| `Clear`（12px） | `CI ear` |
| `中文提交改为` | `中 文 提 交 改 为`（逐字正确，OCR 在汉字间插空格，匹配时已做去空白归一） |

## 验证期间发现并修掉的问题

这些是"跑起来才发现"的东西，留在这里当路标：

1. **截图→坐标的映射一开始照抄了 macOS 的 `/scale`，是错的。**
   macOS 上 `screencapture` 出的是点(pt)图，要除以 backing scale；Windows 的 GDI 截图
   是 **1:1 物理像素**，正确映射是 `global = origin + px`（只有 `--zoom` 才除以放大倍数）。
   症状很隐蔽：`find-text --click` 报成功、也真的点了，但点在按钮上方约 40px 处——
   被"OCR 找到了"的假象盖住。定位手段是把同区域截图下来，用像素扫描找文字的真实行位置，
   与 OCR 报的 `px_rect` 对比，才确认差的是映射而不是 OCR。
   现在 `shot`/`find-text`/`diff`/网格标签四处都已统一为 1:1，并在 `mapping:` 行里写明。

2. **PowerShell 5.1 的 `.Count` 在标量对象上是空值。**
   PS7 给所有对象补了 `.Count`，5.1 只对集合有。函数返回单个元素时会被展开成标量，
   于是 `匹配 {1} 处` 打出 `匹配  处`（数字缺失）。已把所有"函数返回值 + `.Count`"的位置
   用 `@()` 包起来。

3. **BOM 不是格式洁癖，是功能性要求。**
   Windows PowerShell 5.1 读取**无 BOM 的 UTF-8** 脚本时按系统 ANSI 代码页解码；
   中文注释被误解码后会"吃掉"相邻的花括号，导致 `Unexpected token '}'` 或者
   更诡异的运行时现象（本次表现为事件处理器里 `$ctl = [ordered]@{}` 变成 `$null`）。
   已给所有含中文的 `.ps1` 加上 BOM，并在 README 的贡献须知里写清楚。

4. **不能给原生命令传单个 `-` 当占位符。**
   OCR worker 的语言参数一开始用 `-` 表示"用系统默认"，PowerShell 把它当成空参数名，
   直接报 `PSArgumentException`（worker 静默失败，`find-text` 全部返回 1）。
   改用字符串 `auto` 作哨兵。

5. **`Add-Type` 的引用列表要过滤 `.winmd`。**
   PS 5.1 下把 AppDomain 里所有程序集路径丢给 `-ReferencedAssemblies` 时，
   `Windows.Media.winmd` 会让 csc 报 `0x80131047`（invalid assembly name），
   连带图像层编译失败、`shot` 全挂。现在跳过 `.winmd` 与 `.resources.dll`。

6. **`System.Drawing` 在 .NET 10 上被拆成了转发门面。**
   `Bitmap` 在 `System.Drawing.Common`、`Rectangle` 在 `System.Drawing.Primitives`、
   GDI+ 实体在 `System.Private.Windows.GdiPlus`，按名字引用只会得到 CS1069/CS0012。
   现在按"已加载程序集的实际路径"引用（并先造一个 1×1 位图逼 GDI+ 加载）。

7. **`GetWindowThreadProcessId` 在受限令牌的沙箱里会返回无效 PID。**
   本项目在 DSH 自己的沙箱里跑时实测：原生 API 给出的 PID 用 `OpenProcess` 打不开
   （err=87），而 UIA 的 `ProcessId` 是真实且可用的。工具现在先用原生 PID 校验
   （`OpenProcess` 成功才算数），不可信时回落到 UIA —— 两条路都能给出正确的
   进程名 / exe / 文件说明。

8. **`SendInput` 的 `INPUT` 结构体别在 PowerShell 里手工拼。**
   用 `New-Object` 拼嵌套结构体时，`$inp.u.mi = $mi` 这类赋值会静默失效，
   结果是"发送成功（返回 1）但光标纹丝不动"。全部输入合成都放在 C# 里构造。

9. **WinForms 的 `Panel` / `GroupBox` / `ListBox` 不进 UIA 树。**
   测试靶一开始用 Panel 当拖拽区，`find-ax` 怎么也找不到。改为让靶子自己上报控件矩形
   （并做成 DPI 感知，使坐标口径与工具一致），同时把可滚动控件换成 `ListBox`
   （能拿焦点、能报 `TopIndex`，滚轮测试才有可断言的状态）。

10. **`--dry` 的语义要按 macOS 版原样保留、并写清楚。**
    它只挡副作用，不挡读取：`find-text`/`wait-for`/`diff`/`find-ax`/`win list` 在干跑下
    照样截图、OCR、读树。这一点在手册与 skill 里都明说了，避免 agent 误判。

11. **`.cmd` 必须纯 ASCII。**
    启动器一开始用中文写注释，cmd.exe 按 **OEM 代码页**解析 `.cmd`：注释被误解码后
    批处理被拆成一行行"命令"，实测直接开始执行注释碎片（`'��它比' is not recognized...`）
    并弹出交互式 PowerShell。改成纯 ASCII 后正常；套件里加了一条"非 ASCII 字节数必须为 0"
    的断言防回归。（`.ps1` 的规矩正相反：必须带 BOM。两个宿主两套规矩。）

12. **批处理里 `%ERRORLEVEL%` 是解析期展开的** —— 这条是验证方法本身的坑：
    用 `cmd /c "launcher.cmd ... & echo RC=%ERRORLEVEL%"` 测退出码永远得到 0（读到的是
    执行前的值）。改用 `Start-Process cmd -Wait -PassThru` 读 `ExitCode` 才拿到真值，
    实测 0/2 正常透传。

13. **`Select-Object -First N` 会把上游的原生进程一起掐掉。**
    排查失败项时用 `... | Select-String ... | Select-Object -First 20` 看输出，PowerShell 在取够
    20 行后停止上游管道，**正在跑的套件进程被杀在半路**：`finally` 没执行，测试靶变成孤儿进程，
    而且那次运行根本没写结果文件 —— 我一度拿着上一轮的 `results-windows.json` 当新结论。
    现在读套件输出一律先重定向到文件再筛选，并且套件自己会清理孤儿靶子、用带 PID 的状态文件。

14. **`--dry` 的"不执行"要按动作断言，不能只看它打印了什么。**
    一开始只比对了 dry 行文案；补上副作用断言后才有说服力：预演 11 条动作（点击/长按/双击/
    输入/键码/组合键/拖拽/移动/滚轮/剪贴板/窗口移动）之后，靶子的按钮计数、文本框内容、
    拖拽标志、列表滚动位置、窗口矩形、剪贴板**必须一个都没变**。

15. **`--dry find-text --click` 仍然会真的截图 + OCR**（与 macOS 版一致），只把点击换成打印。
    所以它的 dry 断言必须给一个真能识别出文字的区域；用 10×10 的空区域测会得到 exit=1
    —— 那是正确行为，不是 bug（第一版测试就写错了这一点，被套件自己纠正过来）。

16. **装到哪：`%USERPROFILE%\.local\bin` 才是 macOS `~/.local/bin` 的对应位置。**
    实测本机 `C:\Users\<you>\.local\bin` **已存在、且已在用户 PATH 与当前进程 PATH 里**，
    所以把 `dsh-ui.ps1` / `dsh-ui.cmd` 放进去当场就能按名字调用（PowerShell 命中 `.ps1`、
    cmd 命中 `.cmd`），无需重开终端 —— 而 `%LOCALAPPDATA%\dsh-ui\bin` 还得改 PATH 才生效。
    另外：`install.ps1` 一开始会把 `docs/` `skill-win/` `tests/` 一并复制到 `-Prefix` 下，
    一旦 `-Prefix` 指向 `~/.local` 就等于往用户自己目录里倒垃圾；已改成默认**只装可执行文件**
    （与 macOS 版 `install.sh` 一致），要连文档一起装得显式加 `-WithDocs`，并补了断言防回归。

17. **"PATH 里有" 和 "当前进程能看到" 是两件事。** 用户级 PATH 是注册表里给**新进程**用的；
    agent 所在的宿主进程如果启动更早，它和它派生的子进程用的都是旧快照。
    本机恰好两处都已有 `~/.local/bin`，所以按名字可调用；换个环境就要退回绝对路径
    （`C:\Users\<你>\.local\bin\dsh-ui.cmd`）或从仓库直接跑 `dsh-ui.ps1`。

18. **装好二进制 ≠ agent 会用：skill 得单独同步到技能目录。**
    DSH 只从技能根发现技能（源码 `packages/skill/skill-filesystem`：用户级
    `<home>/.dsh/skills`，另有项目级 `<项目>/.dsh/skills`、`<项目>/.agents/skills`），
    而我一开始只把 skill 写在仓库 `skill-win/` 里 —— 当时 `~/.dsh/skills` 是**空的**。
    现在 `install.ps1 -WithSkill` 会复制到 `%USERPROFILE%\.dsh\skills\dsh-windows-ui\SKILL.md`
    （对应 macOS 版 Makefile 的 `SKILL_DEST` + `make sync-skill`），并校验落地文件前 6 行含
    `name:` —— frontmatter 不合格的技能会被**静默忽略**，不校验的话只会表现为"技能就是不出现"。
    实测**无需重启**：同步之后本次会话的技能目录立刻列出了 `dsh-windows-ui`，
    `skill` 工具加载成功并返回基目录 `C:\Users\<you>\.dsh\skills\dsh-windows-ui`
    （技能目录带 watcher，会失效缓存）。

19. **"要记得同步"本身就该被消灭：改用目录联接（junction）。**
    复制模式下每次改 skill 都得记得重跑 `-WithSkill`，这是必然会被忘掉的负担。
    现在 `-WithSkill` 默认把 `~/.dsh/skills/dsh-windows-ui` 做成指向仓库 `skill-win\` 的
    **目录联接**：改完即生效、零同步动作（免管理员；目录级链接也不会被"写临时文件再改名"弄断）。
    实测证据：改完仓库里的 SKILL.md 后**不执行任何命令**，从全局路径读到的内容已经变了；
    往仓库 skill-win 里放一个探针文件，经联接立刻可见，删掉后也立刻消失。
    退路：跨盘/非 NTFS 时自动回退复制模式（`-SkillCopy` 可强制）。

20. **删链接绝不能递归 —— 那是能删掉仓库的。**
    `Remove-Item -Recurse` 作用在目录联接上有可能顺着链接递归进目标；对技能联接来说
    目标就是本仓库。所以安装脚本和验证套件都改成"先识别重解析点、用
    `[System.IO.Directory]::Delete(path, $false)` 只摘链接"（`Remove-LinkOrDir` / `Remove-TreeSafe`），
    并加了一条断言：`-Uninstall -WithSkill` 之后**联接消失但源目录（SKILL.md 及其内容）必须完好**。

21. **状态文件要原子落地，否则读方会扑空。**
    靶子原来用 `Move-Item -Force` 覆盖状态文件，那是"先删目标再改名"：读方正好落在这个窗口里
    就会报"状态文件不存在"（套件跑出过一次假失败）。改成 `[System.IO.File]::Replace()`
    （NTFS 上原子），读方也加了 3 秒退避重试。修完高频读 60 次 0 失败。

22. **依赖"目标窗口可见"的测试，必须自己保证可见性。**
    `find-text`/`wait-for --text`/`under` 都要求目标真的显示在屏幕上；本机是用户的实时桌面，
    只要运行期间有别的窗口抢到前台，这几条就会随机失败（实测截图里出现的是 DSH 自己的对话）。
    套件现在在这些用例前调用 `Focus-Target`（`win list --json` 找序号 → `win focus`），
    把"环境前提"变成测试自己负责的事，而不是假设靶子一直浮在最上面。

## 未验证 / 已知缺口

诚实列出，避免"全绿"被过度解读：

- **多显示器**：本机只有一块屏。虚拟桌面坐标、负坐标、`MOUSEEVENTF_VIRTUALDESK` 归一化
  都已实现，但**没有实测**。
- **提权窗口（UIPI）**：目标进程以管理员运行时合成输入会被系统丢弃，本机未复现；
  手册里把它列为"点击落空"的第一嫌疑。
- **锁屏状态**：预期事件送不到、截图变黑，未测（测试会导致锁屏中断使用）。
- **Windows CI**：没有加 `windows-latest` 工作流——GUI 输入类测试在无桌面的 runner 上
  不可靠，加一个验证不了的工作流不如不加。本文件的结论来自真机手工触发的自动化套件。
- **UIA 覆盖度**：只验证了 WinForms 目标。Electron/CEF 应用（如 VS Code、Steam）的
  UIA 暴露程度差异很大，按 macOS 版的经验应优先 `find-text`。
- **`scroll` 的像素↔档位换算**是近似（Windows 滚轮以行为单位），只在 ListBox 上验证过。
