# DSH-computer-use · dsh-ui

[![CI](https://github.com/rayadesune/DSH-computer-use/actions/workflows/ci.yml/badge.svg)](https://github.com/rayadesune/DSH-computer-use/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%7C%20Windows%2010%2F11-blue)](#windows-%E7%89%88)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://swift.org)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207.x-blue)](docs/REFERENCE-WINDOWS.md)

**给 AI agent 用的图形界面操作原语**：看得见、点得准、能验证。
macOS 版是单文件 Swift CLI，Windows 版是单文件 PowerShell CLI，命令面一致。

`dsh-ui` 是一个单文件 Swift CLI（无第三方依赖），通过注入**真实 HID 事件**（`CGEvent`）
驱动 macOS 桌面。它能操作 AppleScript 与 Accessibility 树覆盖不到的地方——Chromium/CEF
内嵌页面（Steam、Electron 应用）、canvas、游戏、拖拽与滚动——并且每个命令都自带
**坐标映射、审计日志和干跑模式**。

配套的 [`skill/SKILL.md`](skill/SKILL.md) 是一份写给 agent 的操作规范（含 iPhone 镜像
的实测配方与一堆踩过的坑），可以直接放进支持 Skills 的 agent 里。

> A single-file Swift CLI that gives AI agents real HID-level control of the macOS
> desktop — screenshots with coordinate mapping, OCR/AX element location, verified
> waits, and an agent-facing skill. [Jump to English](#english).

---

## 为什么需要它

让 agent 操作 GUI，难点从来不是"点一下"，而是三件事：

| 难点 | `dsh-ui` 的做法 |
| --- | --- |
| **看不见**：截图坐标和点击坐标对不上，多屏更是灾难 | 每次 `shot` 都打印 `global = origin + px/scale` 映射；`displays` 给出两套坐标对照；`--grid` 直接把**全局坐标数字画在图上** |
| **点不准**：小图标靠 OCR 认不出，窗口层级和截图不一致 | OCR（`find-text`）与 AX 树（`find-ax`）双通道；`under X Y` 兜底；`--edge-guard` 防误触窗口缩放；点击前自动补齐前台状态 |
| **验不了**：点了之后不知道有没有生效 | `wait-for --text/--stable/--change` 取代固定 `sleep`；`diff` 量化变化；`--json` 让上层脚本判断 OCR 结果 |

## 特性

- **真实事件注入**：鼠标移动/单击/轻点/长按/双击/右键/拖拽/滚动，键盘按键与文本输入
- **截图即测绘图**：像素→全局坐标映射自动打印，支持局部区域、多显示器、网格标尺、无插值放大
- **双通道定位**：Vision OCR（`find-text`，可 `--list` 转储、`--json` 输出、`--click` 直接点）与
  Accessibility 树（`find-ax`，返回元素真实 frame 与是否可点击）
- **验证原语**：等到文字出现 / 画面稳定 / 画面变化，以及两图差异量化
- **窗口管理**：列出/聚焦/最大化/全屏/移动窗口；`focus` 会等到目标真的成为前台
- **输入兼容**：`type` 走 Unicode 载荷（中文直接输入，绕过输入法）；`keys` 走真实键码
  （解决"只认键码的目标把英文变成 `aaaa`"这一整类问题）
- **安全机制**：审计日志（每条命令留痕）、拦截名单（默认挡密码管理器）、`--dry` 干跑
- **无依赖**：一个 `.swift` 文件，`swiftc` 一条命令编译完

## 快速开始

### 系统要求

- macOS 13+（开发与 CI 在 macOS 14/15 上验证）
- Xcode Command Line Tools（提供 `swiftc`）
- **辅助功能**与**屏幕录制**权限授予**运行 agent 的那个宿主进程**（通常是 Terminal.app / iTerm）

### 安装

```sh
git clone https://github.com/rayadesune/DSH-computer-use.git
cd DSH-computer-use
./install.sh                 # 编译并安装到 ~/.local/bin/dsh-ui
```

或者手动编译（这也是文档里一贯使用的命令）：

```sh
swiftc -O dsh-ui.swift -o ~/.local/bin/dsh-ui
```

用 SwiftPM 也可以：

```sh
swift build -c release       # 产物在 .build/release/dsh-ui
```

### 第一条命令

```sh
dsh-ui guard        # 看拦截名单、审计日志路径、干跑状态
dsh-ui displays     # 屏幕几何：读这个再点任何坐标
dsh-ui shot -R 0,0,600,360 --grid 50 --zoom 2   # 带全局坐标标尺的局部放大图
dsh-ui find-text "保存" --click                 # OCR 找到并点击
dsh-ui --dry click 100 200                      # 只打印、不执行
```

## 命令一览

| 分类 | 命令 |
| --- | --- |
| 鼠标 | `move` `click` `tap` `press` `dclick` `rclick` `drag` `scroll` |
| 键盘 | `type`（Unicode/中文） `keys`（真实键码） `key`（含修饰键） |
| 截图 | `shot`（`-D/-R/-C/-c/-o/--grid/--zoom`） `displays` |
| 定位 | `find-text`（`--all/--fast/--click/--list/--json`） `find-ax`（`--app/--pid/--all`） `under` |
| 窗口 | `win list \| focus \| maximize \| fullscreen \| move` |
| 验证 | `wait-for --text/--stable/--change` `diff` |
| 其他 | `clipboard` `batch` `guard` `pos` `--dry` |

完整手册（含实测数据与坑）：**[docs/REFERENCE.md](docs/REFERENCE.md)**

## 给 Agent 用：安装 skill

[`skill/SKILL.md`](skill/SKILL.md) 是写给 agent 的规范：什么时候该用 GUI 自动化、标准工作流、
坐标陷阱、iPhone 镜像配方、以及本项目踩过的所有坑。放进你的 agent 技能目录即可：

```sh
# DSH
mkdir -p ~/.dsh/skills/dsh-macos-ui && cp skill/SKILL.md ~/.dsh/skills/dsh-macos-ui/
# 其他支持 SKILL.md 的 agent：放到它约定的技能目录
```

把 skill 与你本机安装的副本保持同步（本仓库是唯一真源）：

```sh
make sync-skill              # 仓库 skill/SKILL.md -> ~/.dsh/skills/dsh-macos-ui/
```

### iPhone 镜像

skill 里有一节实测配方，例如：

| 目标 | 做法 | 不要用 |
| --- | --- | --- |
| 回主屏 | `osascript` 点 `显示 → 主屏幕` | 从底部上滑（被 App 自己的抽屉抢走） |
| 打开 App | 聚光灯 + **英文名**（`shortcut` 能找到「捷徑」） | 中文名（繁体系统会变成网页搜索） |
| 输入英文 | `dsh-ui keys "shortcut"` | `dsh-ui type`（会变成 `aaaaaaaa`） |
| 滚动列表 | 用界面自带的搜索框/菜单 | `scroll`（被忽略）、`drag`（部分列表无效） |

## 已知限制

写在前面，省得你踩：

- **"没报错" ≠ "成功了"**。本项目出现过整条 GUI 管线全绿、产物却只有一帧的情况——
  判断动效/多帧输出时，隔约 1 秒截两张图再 `diff`。
- `type` 对**只认物理键码**的目标（含 iPhone 镜像）会把 ASCII 变成 `a`，改用 `keys`。
- iPhone 镜像窗口**忽略合成滚轮事件**，部分列表连合成拖拽也不响应；`drag` 起手点距窗口
  边缘 <10pt 会被 macOS 当成窗口缩放（`--edge-guard` 会告警）。
- `under X Y` 是无障碍命中测试，窗口重叠时可能指错 App，也可能什么都返回不了。
- 部分应用（如 Steam）完全不暴露无障碍树；AX 返回空 ≠ 应用没运行，改用 `find-text`。
- `find-text` 会读到屏幕上的一切文字——**包括 agent 自己的对话窗口**，别把 `--click`
  指向自己的聊天记录。
- 锁屏状态未验证（预期事件无法送达）。

完整清单见 [docs/REFERENCE.md](docs/REFERENCE.md) 的「已知限制」一节。

## Windows 版

Windows 端是同一套命令面的 PowerShell 实现（单文件、无第三方依赖），
把 `CGEvent` 换成 `SendInput`、`screencapture` 换成 GDI、AX 树换成 **UI Automation**、
Vision OCR 换成 **Windows.Media.Ocr**：

```powershell
git clone https://github.com/rayadesune/DSH-computer-use.git
cd DSH-computer-use
# 装到 %USERPROFILE%\.local\bin（对应 macOS 的 ~/.local/bin），并同步全局 skill
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Prefix "$env:USERPROFILE\.local" -WithSkill
dsh-ui displays                       # 屏幕几何（物理像素 / 逻辑尺寸 / 缩放）
dsh-ui shot -R 0,0,600,400 --grid 50 --zoom 2   # 带全局坐标标尺的局部放大图
dsh-ui find-ax "保存" --app 记事本 --click       # UIA 树定位并点击
dsh-ui --dry click 100 200            # 只打印、不执行
```

装到哪：macOS 版是 `~/.local/bin/dsh-ui`，Windows 端对应 `%USERPROFILE%\.local\bin\dsh-ui.cmd`
（本机该目录本来就在用户 PATH 里，装完当场可用；不带 `-Prefix` 则装到 Windows 原生的
`%LOCALAPPDATA%\dsh-ui\bin`）。宿主进程若在安装前启动、PATH 快照过期，用绝对路径调用即可：
`C:\Users\<你>\.local\bin\dsh-ui.cmd displays` 或从仓库直接跑 `dsh-ui.ps1`。
卸载：`.\install.ps1 -Prefix "$env:USERPROFILE\.local" -Uninstall`。

**agent 的 skill 是另一件事**：DSH 只从技能目录读全局技能，所以 skill 得单独装
（`-WithSkill`，对应 macOS 版的 `make sync-skill`）。它落到
`%USERPROFILE%\.dsh\skills\dsh-windows-ui`，与 mac 版 `~/.dsh/skills/dsh-macos-ui/`
同一个约定（DSH 源码 `packages/skill/skill-filesystem` 里的 `user-dsh` 根）：

```powershell
.\install.ps1 -WithSkill                                        # 默认装到 ~/.dsh/skills/dsh-windows-ui
.\install.ps1 -WithSkill -SkillDest D:\skills\dsh-windows-ui    # 换目录
.\install.ps1 -WithSkill -SkillCopy                             # 强制复制模式（默认是联接）
```

默认用**目录联接（junction）**把技能目录指向仓库的 `skill-win/`，所以**改完即生效、不需要任何同步动作**
（这是免管理员的目录级链接；编辑器"写临时文件再改名"也不会把它弄断）。跨盘/非 NTFS 时自动退回复制模式，
那时改完要重跑一次 `-WithSkill`。卸载用 `-Uninstall -WithSkill`：**只摘链接，绝不动仓库目录**。
套件里带一条漂移检测：本机安装的 skill 与仓库副本不一致时直接报错。

| 内容 | 位置 |
| --- | --- |
| 实现（单文件） | [`dsh-ui.ps1`](dsh-ui.ps1) + 启动器 [`dsh-ui.cmd`](dsh-ui.cmd) |
| 安装脚本 | [`install.ps1`](install.ps1)（带 `-Uninstall`） |
| 完整命令手册 | [docs/REFERENCE-WINDOWS.md](docs/REFERENCE-WINDOWS.md) |
| 给 agent 的规范 | [skill-win/SKILL.md](skill-win/SKILL.md) |
| 自动化验证 | [`tests/verify-windows.ps1`](tests/verify-windows.ps1) + 受控测试靶 [`tests/ui-target.ps1`](tests/ui-target.ps1) |
| 本机实测记录 | [docs/VERIFICATION-WINDOWS.md](docs/VERIFICATION-WINDOWS.md) |

要点（细节见手册）：

- **宿主**：Windows PowerShell 5.1 与 PowerShell 7.x 都能跑；实测 **5.1 快约一倍**
  （`find-text` 在 5.1 下进程内直接调 WinRT OCR，PS7 需要派生 5.1 子进程）。
- **坐标**：全部是全局左上**物理像素**，工具自己设 PerMonitorV2 DPI 感知；
  截图是 1:1 的，所以 `global = origin + px`（只有 `--zoom` 时才除以放大倍数）。
- **定位**：`find-ax`（UIA，可 `--pid`/`--app`，支持按窗口标题匹配）优先，`find-text`（OCR）兜底；
  Windows OCR **不提供置信度**，且**中文识别明显弱于 macOS Vision**，手册里给了实测例子。
- **验证**：`tests/verify-windows.ps1` 会拉起一个自建 WinForms 测试靶，按靶子自己写出的状态断言
  「点击真的落在按钮上、输入的字一模一样、拖拽位移符合请求」，本机 54 项全绿。
- ⚠ **未实测**：多显示器、提权窗口（UIPI）、锁屏状态——本机没有对应环境，手册里已标注。

## 项目结构

```
dsh-ui.swift              # macOS 实现（单文件，无依赖）
dsh-ui.ps1                # Windows 实现（单文件 PowerShell；必须保持 UTF-8 with BOM）
dsh-ui.cmd                # Windows 启动器（自动挑 powershell 5.1 / pwsh）
Package.swift             # SwiftPM 清单（可选，用于 swift build）
install.sh                # macOS：编译 + 安装到 ~/.local/bin
install.ps1               # Windows：安装到 %LOCALAPPDATA%\dsh-ui\bin 并加进 PATH
Makefile                  # build / install / test / sync-skill
docs/REFERENCE.md         # macOS 完整命令手册（中文）
docs/REFERENCE-WINDOWS.md # Windows 完整命令手册（中文，含与 macOS 的差异）
docs/VERIFICATION-WINDOWS.md  # Windows 版本机实测记录
skill/SKILL.md            # 给 agent 的操作规范（macOS）
skill-win/SKILL.md        # 给 agent 的操作规范（Windows）
tests/ui-target.ps1       # 受控 WinForms 测试靶
tests/verify-windows.ps1  # Windows 自动化验证套件（54 项断言）
.github/workflows/ci.yml  # 构建 + 冒烟测试 + 文档一致性检查
```

## 开发

```sh
make build      # swiftc -O dsh-ui.swift -o dsh-ui
make test       # 冒烟测试：--help / --dry / keys 映射 / displays
make install    # 安装到 ~/.local/bin
make sync-skill # 同步 skill 到本机 agent 技能目录
```

CI 在每次 push / PR 时于 `macos-14` 上执行：SwiftPM 构建 + `swiftc` 构建、冒烟测试，
以及一项**文档一致性检查**——确保 `--help` 覆盖了分发器里实现的每一条命令。

## 贡献

欢迎提 Issue / PR。两条硬要求：

1. 新命令必须同时更新 `--help`、`docs/REFERENCE.md`（Windows 侧则是 `docs/REFERENCE-WINDOWS.md`），
   否则 CI 会挂。
2. 踩到的坑请写进 `skill/SKILL.md`（Windows 侧 `skill-win/SKILL.md`）的「Known limitations」——
   这个项目最大的价值就是把"看起来能用其实不能用"的边界写清楚。

Windows 侧额外一条：**`dsh-ui.ps1` / `tests/*.ps1` 必须保存为 UTF-8 with BOM**。
Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时会按系统 ANSI 代码页解码，
中文注释会吃掉相邻的花括号导致解析失败（本项目实测踩过一次）。改完可以这样自检：

```powershell
powershell -NoProfile -File tests\verify-windows.ps1 -AlsoPs51
```

## License

[MIT](LICENSE)

---

## English

**HID-level desktop automation primitives for AI agents on macOS.**

`dsh-ui` is a dependency-free single-file Swift CLI that injects real `CGEvent`
mouse/keyboard input, so it can drive surfaces the accessibility tree cannot see:
Chromium/CEF apps, Electron, canvas, games.

```sh
git clone https://github.com/rayadesune/DSH-computer-use.git && cd DSH-computer-use
./install.sh                      # builds and installs to ~/.local/bin/dsh-ui
dsh-ui displays                   # screen geometry, read before clicking
dsh-ui shot -R 0,0,600,360 --grid 50 --zoom 2   # region shot with a global-coordinate grid
dsh-ui find-text "Save" --click   # OCR-locate and click
dsh-ui --dry click 100 200        # print the action, execute nothing
```

Highlights:

- **Every screenshot is a measuring tool** — the pixel→global mapping is printed,
  `--grid` paints global coordinate numbers onto the image, `--zoom` upscales
  without interpolation for pixel-accurate measurement of small icons.
- **Two locating channels** — Vision OCR (`find-text`, with `--list`/`--json`/`--click`)
  and the accessibility tree (`find-ax`).
- **Verification primitives** — `wait-for --text/--stable/--change` and `diff` instead
  of fixed sleeps.
- **Input that actually lands** — `type` for Unicode/CJK, `keys` for real key codes
  (fixes targets that turn ASCII into `aaaa`), `press` for long-press interactions,
  and `click` pre-activates a background app so the first click is not swallowed.
- **Safety** — an audit log for every command, a denylist (password managers by
  default), and `--dry`.

The companion [`skill/SKILL.md`](skill/SKILL.md) is an agent-facing playbook with the
standard workflow, the coordinate traps, measured iPhone Mirroring recipes, and an
honest list of limitations — including the big one: **"no error" is not success**.

MIT licensed. Requires macOS 13+, with Accessibility and Screen Recording granted to
the host terminal.
