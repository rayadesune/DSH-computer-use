# dsh-ui (Windows) 命令参考

> 本文是 Windows 版的完整命令手册。上手看 [README](../README.md)；
> 给 agent 用的操作规范在 [`skill-win/SKILL.md`](../skill-win/SKILL.md)；
> 本机实测记录（含踩过的坑）在 [`VERIFICATION-WINDOWS.md`](VERIFICATION-WINDOWS.md)。

Windows 界面自动化工具，给 DSH 这类 agent 提供一套「**看得见、点得准、能验证**」的 GUI 操作原语。
命令面与 macOS 版 [`dsh-ui.swift`](../dsh-ui.swift) 对齐，实现换成了 Win32：

| 能力 | macOS 版 | Windows 版 |
|---|---|---|
| 事件注入 | `CGEvent` | `SendInput`（真实 HID 事件） |
| 截图 | `screencapture` | GDI `CopyFromScreen`（1:1 物理像素） |
| 无障碍树 | Accessibility (AX) | UI Automation (UIA) |
| 文字定位 | Vision OCR | `Windows.Media.Ocr` |
| 窗口管理 | `NSWorkspace` + AX | `EnumWindows` + `SetWindowPos` |
| 状态目录 | `~/.local/state/dsh-ui` | `%LOCALAPPDATA%\dsh-ui` |

## 安装

```powershell
# 免安装：直接跑（推荐用 Windows PowerShell 5.1 宿主，快一倍）
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-ui.ps1 displays
# 装到 %USERPROFILE%\.local\bin —— 对应 macOS 版的 ~/.local/bin
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Prefix "$env:USERPROFILE\.local"
# 或者 Windows 原生的用户级目录 %LOCALAPPDATA%\dsh-ui\bin
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

**装到哪**：Windows 没有约定俗成的 `~/.local/bin`，但 `%USERPROFILE%\.local\bin`
（即 `C:\Users\<你>\.local\bin`）是它在 Windows 上的对应位置 —— 本机这个目录**本来就在用户 PATH 里**，
装进去当场就能按名字调用，和 mac 版 `~/.local/bin/dsh-ui` 一字之差。`install.ps1` 默认只装
`dsh-ui.ps1` + `dsh-ui.cmd`（与 mac 的 `install.sh` 一致，文档与 skill 留在仓库里），
加 `-WithDocs` 才会把 `docs/` `skill-win/` `tests/` 一起复制到 `-Prefix` 下。
卸载：`install.ps1 -Prefix <同一个> -Uninstall`。

装完后（PATH 里已有该目录的话**当场**）即可直接：

```powershell
dsh-ui displays                  # PowerShell 命中 dsh-ui.ps1，cmd 命中 dsh-ui.cmd，两者都能用
dsh-ui --dry click 100 200
```

如果宿主进程是在安装**之前**启动的、且该目录不在它的 PATH 里，那么按名字叫不到它 ——
这时用绝对路径即可，两条都行：

```powershell
C:\Users\<你>\.local\bin\dsh-ui.cmd displays                          # 包装脚本，自动挑宿主
powershell -NoProfile -File C:\Users\<你>\.local\bin\dsh-ui.ps1 displays   # 直接指定 5.1 宿主
```

### 给 agent 用：安装全局 skill

二进制装好不等于 agent 会用。DSH 只从**技能目录**里发现技能
（源码 `packages/skill/skill-filesystem`：用户级根 = `<home>/.dsh/skills`，
项目级还有 `<项目>/.dsh/skills` 与 `<项目>/.agents/skills`），所以要单独同步：

```powershell
# 装二进制的同时把 skill 同步到 %USERPROFILE%\.dsh\skills\dsh-windows-ui\SKILL.md
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Prefix "$env:USERPROFILE\.local" -WithSkill
# 只同步 skill / 换目录
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -WithSkill
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -WithSkill -SkillDest D:\skills\dsh-windows-ui
```

这与 macOS 版 `Makefile` 的 `SKILL_DEST ?= $(HOME)/.dsh/skills/dsh-macos-ui` + `make sync-skill`
是同一个约定，只是技能名是 `dsh-windows-ui`。安装脚本会顺带校验落地文件的前 6 行里有
`name:` 字段——frontmatter 写错的技能会被 DSH **静默忽略**，校验能当场发现。

实测：同步之后**不需要重启宿主**，新技能立刻出现在会话的技能目录里（技能目录有 watcher，
会失效缓存），`skill` 工具也能正常加载。

**宿主选择**（实测，1920×1080 @125%）：

| 宿主 | `pos` | `shot` | `find-text` | 说明 |
|---|---|---|---|---|
| Windows PowerShell 5.1 | 571ms | 781ms | 941ms | **推荐**：进程内直接跑 WinRT OCR |
| PowerShell 7.x | 1028ms | 1243ms | 1798ms | 可用；OCR 需派生 5.1 子进程 |

## 命令总览

### 鼠标 / 键盘

```powershell
dsh-ui move   X Y
dsh-ui click  X Y [MS] [--no-activate]   # 左键单击（默认 30ms）
                                         # 落点窗口不在前台时先激活再点击（--no-activate 关闭）
dsh-ui tap    X Y [MS]                   # 轻点（默认 60ms）
dsh-ui press  X Y [MS]                   # 长按（默认 800ms）
dsh-ui dclick X Y                        # 左键双击
dsh-ui rclick X Y                        # 右键单击
dsh-ui drag   X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N]
                          [--momentum F] [--edge-guard N]
dsh-ui scroll N [--drag] [--px-per-notch N]
dsh-ui type   TEXT                       # KEYEVENTF_UNICODE：中文/emoji 都能打，绕过输入法
dsh-ui keys   TEXT                       # ASCII 逐字符发真实键码（大写/符号自动带 shift）
dsh-ui key    KEY                        # 按键，如 key ctrl+shift+s / key enter / key win+r
dsh-ui pos                               # 打印光标位置
```

- 坐标一律是**全局左上物理像素**，与截图、UIA 完全同一套口径。
- `type` 与 `keys` 的区别：`type` 走 Unicode 载荷，任何字符都行（含中文、emoji）；
  `keys` 走真实虚拟键码（`VkKeyScan` 按当前键盘布局解析），只支持布局产得出的字符，
  产不出的（CJK）会被跳过并在结尾报告。要往「只认键码」的目标打字用 `keys`。
  `dsh-ui --dry keys "Ab-1!"` 会逐字符打印映射，不真的敲键盘。
- `key` 的修饰键：`ctrl`/`control`/`cmd`/`command` → Ctrl（mac 习惯直接可用）、
  `shift`、`alt`/`option`、`win`/`windows`/`meta`/`super` → Win。
- `scroll` 正数 = 向下滚（内容上移）。Windows 滚轮事件以 120 为单位（≈一行），
  像素→档位按 `--px-per-notch`（默认 100px/档）折算，分批发事件；`--drag` 改用拖拽模拟。

### 截图

```powershell
dsh-ui shot [-D N] [-R X,Y,W,H] [-C] [-c] [-o PATH] [--grid [N]] [--zoom [N]]
dsh-ui displays [--json]
```

- `-D N`：第 N 块屏（主屏恒为 `#1`）；`-R X,Y,W,H`：全局物理像素区域。
- `-C` 在图上补画光标箭头（GDI 截图本身不含光标）；`-c` 直接把图放进剪贴板。
- `--grid [N]`（默认 50pt）叠加**带全局坐标数字**的标尺：红线标 x、蓝线标 y，每 5 格加粗。
  两条轴都从左上角步进，**数字与线始终对齐**（macOS 版两条轴分别从上下两端步进，中段才对得上）。
- `--zoom [N]`（默认 2）用最近邻放大，便于逐像素量取小图标。
- 派生图写在原图旁（`-zoom2x` / `-grid` 后缀），原图保留，路径会在输出里打印。

```
$ dsh-ui shot -R 0,0,600,400 --grid 50 --zoom 2
ok path=C:\...\shot-...-zoom2x-grid.png rect on display #1 px=600x400 pt=480x320 scale=1.25 origin=(0,0) zoom=2x grid=50pt
   mapping: global_x = 0 + px_x/2   global_y = 0 + px_y/2   (图被放大 2x)
   原图: C:\...\shot-....png
   网格已把**全局左上坐标**写在图上：红线标 x，蓝线标 y，粗线是 5 格整数倍
```

**映射约定（与 macOS 版不同，务必注意）**：Windows 上截图就是 1:1 物理像素，
所以 `global = origin + px`；只有 `--zoom` 放大时才除以放大倍数。
`pt=` 是把物理像素按显示器缩放折算出的逻辑尺寸，仅供参考，**不是**点击坐标的单位。

量 `✕`、`⌄`、`▶` 这类纯图标按钮时不要目测缩放预览图——用 `--grid` 标尺量，或按上式的映射算。

`displays` 输出：

```
$ dsh-ui displays
main height = 1080px  (Windows 全局坐标本来就是左上原点，无需换算)
#1 pt=1536x864 px=1920x1080 scale=1.25 origin_tl=(0,0) work_tl=(0,0) 1920x1020 dpi=120 primary
```

### 定位（两条互补通道）

```powershell
dsh-ui find-text "文字" [--all] [--fast] [--click] [--list] [--json] [-D N] [-R X,Y,W,H] [--lang en-US]
dsh-ui find-ax   "文字" [--app 名称] [--pid N] [--all] [--json] [--max N] [--click]
dsh-ui under X Y
```

| | `find-text`（Windows OCR） | `find-ax`（UI Automation 树） |
|---|---|---|
| 原理 | 端上 OCR 识别画面文字 | 读系统无障碍树 |
| 精度 | 文字块 bbox；**拉丁文本很准，中文有字符级误识** | **元素真实 frame**，最准 |
| 覆盖 | 任何能看见的文字（含 canvas/CEF/游戏） | 原生控件好；WinForms 的 Panel/GroupBox/ListBox 不暴露 |
| 置信度 | **无**（Windows OCR 不提供，输出里是 `conf=n/a`） | 附带 role / 是否可点击 |
| 速度 | 端到端 ≈0.9–1.8s | 端到端 ≈0.65–1.1s |

两者互补：**先 `find-ax`，找不到再 `find-text`**。

`find-text --json` 输出单个机器可读对象，未命中返回 1：

```json
{"capture":{"label":"display #1 (main)","origin":[0,0],"px":[1920,1080],"pt":[1536,864],"scale":1.25,"path":"..."},
 "clicked":[197,333],"hits":[...],"matches":[...],"needle":"Submit","ok":true}
```

每个 hit/match 的字段：`conf`（恒为 null）、`global`（全局像素中心）、`px_center`、`px_rect`、`text`。

`find-ax` 输出：

```
$ dsh-ui find-ax "Submit" --pid 12345
ok AX 匹配 1 处
  [0] Button title="Submit" app=Windows PowerShell pos=(141,318) size=110x34 pressable=true -> dsh-ui click 196 335
```

- **永远加 `--app` 或 `--pid`**：不限定会扫所有进程。`--app` 匹配 exe 名、文件说明、
  **窗口标题**三者的子串（`--app "DSH UI Target"` 这类按标题叫法可用）。
- `--json` / `--click` / `--max N`（默认每进程最多 20 条命中）是 Windows 版新增。

### 窗口管理

```powershell
dsh-ui win list [--json]           # 列出窗口：位置/尺寸/中心点/pid/显示器/状态
dsh-ui win focus N                 # 聚焦第 N 个窗口（轮询到真的成为前台才返回）
dsh-ui win maximize N              # 填满所在屏幕的工作区（排除任务栏）
dsh-ui win fullscreen N            # 填满整块屏幕（Windows 没有 macOS 式原生全屏）
dsh-ui win move N X Y [W H]        # 移动/缩放
dsh-ui win close N | minimize N | restore N
```

```
$ dsh-ui win list
[1] Microsoft Edge — "示例页面" pos=(-9,-9) size=1938x1038 center=(960,510) pid=28356 max
[2] Windows 资源管理器 — "下载" pos=(436,112) size=1274x892 center=(1073,558) pid=14488
```

- 只列**可见、有标题、未被 DWM 隐藏**的顶层窗口，前台窗口排在最前，其余按 z 序；
  桌面（Progman）、任务栏、托盘辅助窗口已过滤。最小化窗口会标 `min` 并用还原后的矩形。
- **序号每次调用重新枚举，跨调用不稳定**；要紧的操作请重新 `win list` 取序号。

### 验证（取代固定 sleep）

```powershell
dsh-ui wait-for --text "文字" [--timeout 20] [--interval 0.6] [-D N] [-R X,Y,W,H]
dsh-ui wait-for --stable [--timeout 20]
dsh-ui wait-for --change PATH [--timeout 20] [--min-change 2000] [--threshold 12]
dsh-ui diff A.png B.png [--threshold 12] [-D N] [-R X,Y,W,H]
```

- `--text`：等到 OCR 出现指定文字（中文按「去掉所有空白后」比较，避免 OCR 在汉字间插空格）。
- `--stable`：等到连续两帧像素完全一致。
- `--change`：等到画面**变化并稳定**。要求相对参考图变化 ≥ `--min-change` 像素，
  **且**帧间残留 ≤ `max(20, 变化量/3)`——后者过滤旋转指示器、秒表这类持续动画的误报。
- `diff`：输出变化像素数、占比、变化区域 bbox 及对应全局坐标中心。加 `-R X,Y,W,H`
  会把**比较范围限制在该区域**；阈值为每像素 `|ΔR|+|ΔG|+|ΔB| > threshold`。

```
$ dsh-ui diff a.png b.png
ok 变化 47994 像素 (99.99% of 全图)
   bbox_px=(0,0)-(299,159) -> global=(0,0)-(299,159) center=(149,79)
```

### 其他

```powershell
dsh-ui clipboard get | set TEXT
dsh-ui batch [-c]                # 从 stdin 读脚本逐条执行，-c 出错继续
dsh-ui guard                     # 查看拦截名单、审计日志、干跑状态、宿主/OCR/DPI
dsh-ui under X Y                 # 该坐标下是哪个窗口/元素（排查拦截与点击落空）
dsh-ui --dry <任意命令>          # 干跑：只打印动作，不执行
```

`batch` 示例：

```powershell
@'
# 打开搜索框并输入
find-ax "搜索" --app 记事本 --click
clipboard set 鬼武者
key ctrl+v
key enter
wait-for --text "鬼武者" --timeout 10
'@ | dsh-ui batch
```

支持单/双引号包裹的参数，`#` 开头是注释，每条子命令**单独写审计日志**。
Windows 版会吃掉 CRLF 的行尾 `\r`（macOS 版没做，CRLF 脚本会带上 `\r` 导致匹配失败）。
注意 `--dry` 在 `batch` 里是**粘性**的：某一行带了 `--dry`，后续所有行都变成干跑（与 macOS 版一致）。

## 坐标与 DPI（重要）

1. 工具启动时会把进程设为 **PerMonitorV2 DPI 感知**，因此读到的窗口矩形、光标位置、
   截图、UIA 坐标**全部是物理像素**，互相一致。
2. **DPI 不感知的老程序看到的是虚拟化后的逻辑坐标**：在 125% 缩放的屏上，
   同一位置它报 (800,400)、你这边是 (1000,500)。把测试靶程序做成 DPI 感知即可消除这类差异
   （`tests/ui-target.ps1` 就是这么做的）。
3. 多显示器：虚拟桌面坐标可为负（左侧副屏 x 为负、上方副屏 y 为负），
   鼠标绝对移动用的是 `MOUSEEVENTF_VIRTUALDESK` 归一化坐标，支持负坐标。
   ⚠ 本机只有单屏，**多屏路径未实测**。

## 安全机制

| 机制 | 说明 |
|---|---|
| 审计日志 | 每条命令写入 `%LOCALAPPDATA%\dsh-ui\audit.log`，含时间、退出码、pid、是否干跑、原始参数 |
| 拦截名单 | `%LOCALAPPDATA%\dsh-ui\denylist.txt`，命中则拒绝执行并返回 exit 3 |
| 干跑模式 | `--dry` 只打印将要执行的动作 |
| 退出码 | 0 成功 / 1 未命中或超时 / 2 用法错误 / 3 被拦截 |

审计行格式（与 macOS 版格式不同，字段化便于机器解析）：

```
2026-09-11T12:17:58+08:00 code=3 pid=16444 dry=0 cmd=click 336 395
```

拦截名单的判定：对**鼠标类动作**看落点下的窗口，对**键盘类动作**看当前前台窗口，
用「进程名 / 应用说明 / 窗口标题」三者做**不区分大小写的子串匹配**（macOS 版是精确相等，
且只在鼠标动作上生效）。首次运行会写入一份默认名单（常见密码管理器等）。

被拦截的动作包括：`move` `click` `tap` `press` `dclick` `rclick` `drag` `scroll --drag`
`find-text --click` `find-ax --click`，以及 Windows 版额外覆盖的 `type` `keys` `key`。

## 典型工作流

```powershell
# 0. 打开目标后先最大化，元素一次看全，少滚动少漏项
dsh-ui win list; dsh-ui win maximize <序号>
# 1. 先试 UIA（快且准）
dsh-ui find-ax "搜索" --app <目标应用>
# 2. 不行再 OCR（注意 -R 限定区域，OCR 会读到你自己的对话）
dsh-ui find-text "搜索" -R <区域> --click
# 3. 等结果，别用 sleep
dsh-ui wait-for --text "结果标题" --timeout 10
# 4. 需要确认变化范围时
dsh-ui diff before.png after.png
```

## 已验证场景（本机实测）

完整记录见 [`VERIFICATION-WINDOWS.md`](VERIFICATION-WINDOWS.md)：42 项断言全绿，覆盖
CLI 基线/退出码/审计、区域截图与网格像素、diff、wait-for 三种模式、OCR 与 UIA 定位精度、
窗口 move/focus/maximize、真实点击（OCR 命中坐标与按钮中心误差 1px）、中文与 ASCII 输入、
真实键码、`ctrl+a`/`delete`、剪贴板粘贴、拖拽落点、滚轮滚动、拦截名单 exit 3、batch 逐条审计，
以及在 **Windows PowerShell 5.1** 宿主下的重复验证。

## 已知限制

- **Windows OCR 的中文识别明显弱于 macOS Vision**：实测 `无标题` → `无 》 玺 题`、
  12px 的 `Clear` → `CI ear`，而拉丁文本（`Submit`、`TARGET-ALPHA-9931`、`Windows (CRLF)`）
  几乎全对。中文定位优先走 `find-ax`；必须走 OCR 时用更短的关键词，并接受字符级误识。
- **OCR 不提供置信度**：输出里 `conf=n/a`，JSON 里 `conf=null`；`--fast` 被接受但无效
  （Windows OCR 只有一种模式）。
- **`find-text` 会读到你自己的对话**：对 DSH 窗口所在屏做 OCR，识别结果包含本会话内容，
  `--click` 可能点中自己的聊天文字。已知区域时用 `-R` 限定，或点击前用 `under X Y` 确认归属。
- **`find-ax` 必须限定范围**：不限定会扫所有进程把无关窗口也算进来。永远用 `--app`/`--pid`。
- **WinForms 的 Panel / GroupBox / ListBox 不向 UIA 暴露**（实测：一个含这些控件的窗口只暴露
  15 个元素，Pane 与 List 都不在树里）。这类容器里的控件定位只能靠 `find-text` 或几何推算。
- **`--dry` 只挡副作用，不挡读取**：`find-text`/`wait-for`/`diff`/`find-ax`/`win list`/`pos`/
  `under`/`clipboard get` 在干跑下仍会真的截图、OCR、读无障碍树（与 macOS 版一致）。
- **提权窗口收不到合成输入**（UIPI）：目标进程以管理员运行时 `SendInput` 会被系统丢弃。
  本机未复现该场景，届时需要让宿主也以管理员身份运行。⚠ **未实测**。
- **锁屏状态无效**（⚠ 未实测）：预期事件送不到、截图变黑。锁定会中断使用，未做验证。
- **多显示器未实测**：实现按虚拟桌面坐标做了归一化，但本机只有一块屏。
- **`scroll` 的像素→档位换算是近似**：Windows 滚轮本身是「行」为单位的，默认 100px/档；
  界面自带平滑滚动时实际位移会与请求值有出入，用 `--px-per-notch` 校准。
- **`win fullscreen` 不是 macOS 那种原生全屏空间**：只是把窗口铺满整块显示器（含任务栏区域），
  窗口样式/边框仍在；再执行一次会还原到工作区。
- **`wait-for --stable` 在播放视频/动画的界面上必然超时**，此时改用 `--text` 或 `--change`。
- **`under X Y` 也会指错**：它是 z 序命中测试 + UIA 命中测试的组合，重叠窗口下可能给出上层窗口。
  点击要紧时用 `shot`/`win list` 佐证。
- **没有内建交互式选窗口（`-w`）模式**，窗口矩形请用 `win list` 获取。
- **本文件与脚本必须保持 UTF-8 with BOM**：Windows PowerShell 5.1 读取无 BOM 的 UTF-8
  脚本时会按系统 ANSI 代码页解码，中文注释会吃掉相邻的花括号导致解析失败（本项目实测踩过）。
