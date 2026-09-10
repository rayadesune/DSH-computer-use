# dsh-ui

macOS 界面自动化工具，给 DSH 这类 agent 提供一套「**看得见、点得准、能验证**」的
GUI 操作原语。

提供的是**真实 HID 事件**（`CGEvent`），因此能操作 AppleScript / Accessibility
树覆盖不到的地方：Chromium/CEF 内嵌页面（Steam、Electron 应用）、canvas、
游戏、拖拽与滚动。

## 安装

```sh
swiftc -O dsh-ui.swift -o ~/.local/bin/dsh-ui
```

`~/.local/bin` 已加入 `~/.zprofile` 的 `PATH`，新开终端即可直接调用。

## 命令总览

### 鼠标 / 键盘

```sh
dsh-ui move   X Y                # 移动光标
dsh-ui click  X Y [MS] [--no-activate]
                                 # 左键单击，可指定按下时长（默认 30ms）
                                 # 落点所属 App 不在前台时，会先激活它再点击，
                                 # 避免 macOS 把第一击当成「激活窗口」吃掉
dsh-ui tap    X Y [MS]           # 轻点（默认 60ms，网页/移动端控件更稳）
dsh-ui press  X Y [MS]           # 长按（默认 800ms，iOS 长按菜单/右键式交互）
dsh-ui dclick X Y                # 左键双击
dsh-ui rclick X Y                # 右键单击
dsh-ui drag   X1 Y1 X2 Y2 [选项] # 拖拽，默认参数与旧行为一致
                                 #   --ms N          总移动时长（默认 216）
                                 #   --steps N       分段数（默认 12）
                                 #   --hold N        按下后停顿再移动（默认 80）
                                 #   --settle N      起手前停顿（默认 80）
                                 #   --momentum F    抬手后的惯性尾巴（默认 0）
                                 #   --edge-guard N  起手点距窗口边缘 <N pt 时告警（默认 12）
dsh-ui scroll N [--drag]         # 垂直滚动 N 像素；--drag 用拖拽模拟
                                 #（有些界面完全忽略合成滚轮事件，例如 iPhone 镜像）
dsh-ui type   TEXT               # 输入文本（支持中文，绕过输入法）
dsh-ui keys   TEXT               # ASCII 逐字符发**真实键码**（大写/符号带 shift）
dsh-ui key    KEY                # 按键，支持 cmd+shift+4
dsh-ui pos                       # 打印光标位置
```

`type` 与 `keys` 的区别（实测踩过）：`type` 用「virtualKey 恒为 0 + unicode 载荷」注入。
macOS 原生控件认这个载荷，所以本机可用；但像 **iPhone 镜像** 这类按 HID 键码查键盘布局
的目标，会把所有 ASCII 变成 `a`（`type "shortcut"` → `aaaaaaaa`），而非 ASCII 才回退到
载荷——这就是「中文正常、英文全变 a」的成因。要往这类目标打字就用 `keys`。
`dsh-ui --dry keys "Ab-1!"` 会逐字符打印映射，不真的敲键盘。

### 截图

```sh
dsh-ui shot [-D N] [-R X,Y,W,H] [-C] [-c] [-o PATH] [--grid [N]] [--zoom [N]]
dsh-ui displays
```

`--grid [N]`（默认 50pt）在图上叠加**带全局坐标数字**的标尺：红线标 x、蓝线标 y，
每 5 格加粗。`--zoom [N]`（默认 2）用无插值方式放大，便于逐像素量取小图标。
派生图写在原图旁（`-grid` / `-zoomNx` 后缀），原图保留，路径会在输出里打印。

```sh
$ dsh-ui shot -R -1010,150,80,260 --grid 50 --zoom 2
ok path=/tmp/.../shot-...-zoom2x-grid.png rect on display #2 px=160x520 pt=80x260 scale=2 origin=(-1010,150) zoom=2x grid=50pt
   mapping: global_x = -1010 + px_x/4   global_y = 150 + px_y/4
   原图: /tmp/.../shot-....png
```

量 `✕`、`⌄`、`▶` 这类纯图标按钮时**不要目测缩放预览图**——本项目就是这么把坐标量偏
30pt、连点四次都没删掉一个动作的。用网格图标尺量。

`shot` 会自动打印坐标映射：

```
$ dsh-ui shot -D 2
ok path=/tmp/dsh-ui-shots/shot-...png display #2 px=2732x2048 pt=1366x1024 scale=2 origin=(-1366,0)
   mapping: global_x = -1366 + px_x/2   global_y = 0 + px_y/2
```

`displays` 给出两套坐标的对照：

```
$ dsh-ui displays
main height = 900pt  (左下->左上 换算基准)
#1 pt=1440x900  px=2880x1800 scale=2 origin_tl=(0,0)     frame_bl=(0,0)       visible_tl=(0,30) 1440x870
#2 pt=1366x1024 px=2732x2048 scale=2 origin_tl=(-1366,0) frame_bl=(-1366,-124) visible_tl=(-1366,30) 1366x994
```

### 定位（两条互补通道）

```sh
dsh-ui find-text "哔哩哔哩" [--all] [--fast] [--click] [--list] [--json] [-D N] [-R X,Y,W,H]
dsh-ui find-ax  "搜索商店" [--app 名称] [--pid N] [--all]
```

`--json` 输出单个机器可读对象（`capture` / `hits` / `matches` / `clicked`），
没匹配到时返回 1，方便上层脚本直接判断而不用解析人读文本；`--json` 可以和
`--click` 合用，在同一次调用里点掉最佳匹配：

```
$ dsh-ui find-text "新会话" --json
{"capture":{...},"clicked":null,"hits":[...],"matches":[{"conf":1,"global":[93,470],...}]}
```

| | `find-text`（Vision OCR） | `find-ax`（Accessibility 树） |
|---|---|---|
| 原理 | 端上 OCR 识别画面文字 | 读系统无障碍树 |
| 精度 | 文字块 bbox，±几像素 | **元素真实 frame**，最准 |
| 覆盖 | 任何能看见的文字 | 原生 App 好，CEF/Electron 差 |
| 速度 | 端到端 ≈0.75s（含截图；OCR 本身 ≈0.4s） | 端到端 0.24–0.48s（AX 树遍历为主） |
| 额外信息 | 置信度 | role / 是否可点击 |

两者互补：**先 `find-ax`，找不到再 `find-text`**。

```
$ dsh-ui find-text "Developer" --click
ok "Developer" 匹配 1 处 (display #1 (main), mapping: global = (0,0) + px/2)
  [0] "Developer" conf=1.00 px_center=(569,1057) -> dsh-ui click 284 528
  已点击 (284,528)
```

### 窗口管理

```sh
dsh-ui win list                  # 列出所有窗口：位置/尺寸/中心点/pid
dsh-ui win focus N               # 聚焦第 N 个窗口（会等到它真的成为前台再返回）
dsh-ui win maximize N            # 填满所在屏幕的可见区（排除菜单栏/Dock）
dsh-ui win fullscreen N          # 切换 macOS 原生全屏
dsh-ui win move N X Y [W H]      # 移动/缩放第 N 个窗口
```

`win focus` 会**轮询到目标 App 真正成为前台**才返回（最多约 700ms），失败会打印警告。
原因：`activate()` 是异步的，紧接着投递的点击会落在「还没成为前台」的窗口上，被
macOS 当成激活点击吃掉——这就是「第一次点击没反应、要点两次」的根因。前台判定用
AX 的 `kAXFocusedApplication` 实时查询，**不要**用 `NSWorkspace.frontmostApplication`：
它是靠 run loop 刷新的，而 dsh-ui 是一次性 CLI、从不跑 run loop，读到的常是过期值
（曾因此把成功的激活误报为失败）。

`win list` 是拿到窗口矩形最快的方式（比手写 AX 探测脚本省事）：

```
$ dsh-ui win list
[3] Safari浏览器 — "能否像 Codex 控制 Mac" pos=(-1358,38) size=1350x978 center=(-683,527) pid=6503
[4] iPhone镜像 — "iPhone镜像" pos=(-432,129) size=344x756 center=(-260,507) pid=15903
```

### 验证（取代固定 sleep）

```sh
dsh-ui wait-for --text "首页" [--timeout 20] [--interval 0.6] [--fast]
dsh-ui wait-for --stable      [--timeout 20]
dsh-ui wait-for --change PATH [--timeout 20] [--min-change 2000] [--threshold 12]
dsh-ui diff A.png B.png [--threshold 12] [-D N] [-R X,Y,W,H]
```

- `--text`：等到 OCR 出现指定文字
- `--stable`：等到连续两帧完全一致
- `--change`：等到画面**变化并稳定**。要求相对参考图的变化 ≥ `--min-change`
  像素，**且**帧间残留 ≤ 变化量的 1/3。后者是为了过滤旋转指示器、秒表这类
  持续动画造成的误报。
- `diff`：输出变化像素数、占比、变化区域 bbox 及对应的全局坐标中心。
  加 `-R X,Y,W,H` 会把**比较范围限制在该区域**（不只是换算坐标），用于只看某个
  控件是否变化；不加则比较整图。

```
$ dsh-ui diff a.png b.png
ok 变化 857159 像素 (12.4%)
   bbox_px=(120,340)-(900,780) -> global=(60,170)-(450,390) center=(255,280)
```

### 其他

```sh
dsh-ui clipboard get | set TEXT
dsh-ui batch [-c]                # 从 stdin 读脚本逐条执行，-c 出错继续
dsh-ui guard                     # 查看拦截名单、审计日志、干跑状态
dsh-ui under X Y                 # 该坐标下是哪个 App（排查拦截/点击落空）
dsh-ui --dry <任意命令>          # 干跑：只打印动作，不执行
```

`batch` 示例：

```sh
dsh-ui batch <<'EOF'
# 打开搜索框并输入
find-text "搜索商店" --click
clipboard set 鬼武者
key cmd+v
key return
wait-for --text "鬼武者" --timeout 10
EOF
```

注意：`batch` 支持单/双引号包裹的参数，且每条子命令都会**单独写入审计日志**。

## 坐标约定（重要）

所有坐标都是 **全局左上原点**，与 `screencapture -R`、`CGEvent` 一致：

| 屏幕 | 坐标特征 |
|---|---|
| 主屏 | `(0,0)` 起，x/y 均为正 |
| 左侧副屏 | x 为负 |
| 上方副屏 | y 为负 |

**`NSScreen.frame` 用的是左下原点**，两者换算时容易差一个屏高的偏移量
（本项目实测踩过一次，偏差正好等于副屏的 y 原点 `-124`）。
用 `dsh-ui displays` 看 `origin_tl` 与 `frame_bl` 的差异即可，
不要直接拿 `frame.origin` 去点击。

## 安全机制

| 机制 | 说明 |
|---|---|
| 审计日志 | 每条命令写入 `~/.local/state/dsh-ui/audit.log`，含时间、参数、退出码 |
| 拦截名单 | `~/.local/state/dsh-ui/denylist.txt`，命中则拒绝执行并返回 exit 3 |
| 干跑模式 | `--dry` 只打印将要执行的动作 |
| 退出码 | 0 成功 / 1 未命中或超时 / 2 用法错误 / 3 被拦截 |

拦截名单默认包含常见密码管理器（1Password、Keychain、Bitwarden、LastPass）。
判断方式是用 `AXUIElementCopyElementAtPosition` 查**点击位置下的 App**，
比"看前台 App"更准。

## 权限要求

| 权限 | 授予对象 | 用途 |
|---|---|---|
| 辅助功能 (Accessibility) | 宿主程序（Terminal.app / iTerm） | 注入事件、读 AX 树、拦截名单判定 |
| 屏幕录制 (Screen Recording) | 宿主程序 | `screencapture` 截图 |

系统设置 → 隐私与安全性 → 对应项。

## 典型工作流

```sh
# 0. 打开 App 后先把窗口最大化，元素一次看全，少滚动少漏项
dsh-ui win list && dsh-ui win maximize <序号>
# 1. 先试 AX（快且准）
dsh-ui find-ax "搜索商店"
# 2. 不行再 OCR
dsh-ui find-text "搜索商店" --click
# 3. 等结果，别用 sleep
dsh-ui wait-for --text "鬼武者" --timeout 10
# 4. 需要确认变化范围时
dsh-ui diff before.png after.png
```

## 已验证场景

- Steam 客户端（CEF 页面）搜索框输入中文、点击结果、处理年龄验证 `<select>` 下拉
- iPhone 镜像窗口内点击图标
- macOS 菜单栏、原生对话框
- 副屏与多显示器坐标换算（`-R` 局部截图与整屏截图对应区域**逐像素无差异**；文件字节 SHA 会因 PNG 元数据不同而不同，不能用来判断对齐）
- OCR 中文定位（`个人收藏`/`桌面`/`Developer` 置信度 1.00）

## 已知限制

- **`--fast` 的 OCR 对中文不可用**：实测同一屏，`.accurate` 正确识别
  `鬼武者 Way of the Sword`（置信度 1.00），`.fast` 输出 `é *(* / WJ / A* 9R`
  这类乱码。`--fast` 只适合拉丁文本或粗略预检。
- `wait-for --stable` 在播放视频/动画的界面上必然超时（实测预告片 1.5 秒内
  变化 458110 像素），此时改用 `--text` 或 `--change`。
- **`shot`/`find-text`/`wait-for` 默认只处理 1 号屏（主屏）**：目标窗口在别的屏幕上
  时必须加 `-D N`，否则会对着错误的屏幕 OCR，明明看得见的文字却报"未找到"。
- **`find-text` 会读到 agent 自己的对话**：对 DSH 窗口所在屏做 OCR，识别结果里
  直接包含本会话的消息和思考内容，因此 `find-text ... --click` 可能点中自己的聊天
  文字。已知区域时用 `-R` 限定，或点击前用 `under X Y` 确认归属。
- **`find-ax` 必须限定应用范围**：不限定会扫描所有前台 App，把 **agent 自己的对话文字**
  （渲染在 Safari 窗口里）当成命中项。实测不限定搜"新增"命中 26 处、第一条是对话里的
  "新增命令"；`--app 钉钉` 则精确返回 11 处。**永远用 `--app`/`--pid`**。
- **单次 OCR 未命中不能推断原因**：`find-text "新增"` 曾在钉钉工具栏上失败，而
  `find-ax --app 钉钉` 立刻找到 `AXButton`。最初的猜测"彩色按钮上的白字读不出"
  已被对照实验推翻——蓝/绿/红底白字、13px 小号、带 `+` 图标前缀，全部正确识别
  （置信度最高 1.00），"导出"也读对了，且无法复现原失败。同一次 OCR 在该页面把
  "导出"读成"山导出"、"胡瑞峰"读成"乙胡瑞峰"，字符级误识是最可能的原因。
  结论前先用 `find-text --list` 转储全部识别块；能走 AX 就优先 `find-ax`。
- **网页搜索框可能不响应 `cmd+a` + 输入**：先 `cmd+a` + `delete` 清空，再输入。
- **部分应用完全不暴露无障碍树**：Steam 的界面明明在屏幕上，`win list` 和
  `find-ax --pid <steam>` 都一无所获。这是**按应用**而非按框架：同样基于 Web 技术的
  钉钉就同时暴露了窗口和元素。**AX 返回空 ≠ 应用没运行**——用 `shot` 找到窗口，
  再用 `find-text` 定位元素。
- **锁屏状态无效**（⚠️ 未实测）：预期锁定后事件无法送达、截图变黑。锁定屏幕会中断使用，本项目未验证。
- **OCR 首次调用慢**：本机首次调用实测 48s（Vision 模型加载）；之后每个新进程调用 OCR 约 0.4s。重启后是否会再次变慢未验证。
- ~~副屏上 `-C` 可能不渲染光标~~ **已证伪**：实测主屏 591 像素、副屏 482 像素都在光标位置变化，`-C` 在两块屏上都渲染光标；此前判断错误源于在缩小 3 倍的预览图里没认出光标。
- **`scroll` 必须发出完整手势，单个大幅度事件会被忽略**：早期实现只发一个事件，
  钉钉导航面板对它毫无反应（实测 600px 单事件 → 0 变化），而重放「phase 序列
  （began→changed→ended→momentum）+ 每步 ≤20px」后，同一面板滚动 17%。现已改为
  默认发手势。修正后实测：钉钉导航面板 17.18%、钉钉数据表格 8.86%、
  **Safari/WebKit 5.17%**（修正前 Safari 完全无效）。
- `type` 对某些只认物理键码的原生控件（如 `<select>` 下拉菜单）无效，
  此时改用 `key` 发真实键码。
- **`type` 的 ASCII 在「按键码查布局」的目标上会退化成 `a`**（实测 iPhone 镜像：
  `type "shortcut"` → `aaaaaaaa`，而同一目标的 `type "照片"` 正常）。成因是
  `typeString()` 每字符都用 `virtualKey 0` + unicode 载荷：原生 Cocoa 控件认载荷，
  这类目标只认键码、只有布局产不出的字符（CJK）才回退到载荷。改用 `keys`。
- **`under X Y` 会指错、也会什么都返回不了**：它是无障碍命中测试，实测在一个像素
  明显属于微信的点上返回了「访达」（桌面），另一个明明有窗口的点返回
  「没有 AX 元素」。点击要紧时用 `shot`/`win list` 佐证。
- **镜像窗口底边是缩放手柄**：起手点距底边 ~10pt 内的拖拽会变成窗口缩放
  （实测把 454×994 的窗口缩成 271×598）。`drag` 默认以 `--edge-guard 12` 告警，
  误缩后用 `win maximize N` 恢复。
- **iPhone 镜像忽略合成滚轮事件**，部分列表（如快捷指令的动作列表）连合成拖拽也
  不响应。先用 `scroll N --drag` 试；仍不动就改用界面自带的搜索框/菜单直达。
- **"没有报错" ≠ "成功了"**：本项目出现过整条管线全绿、产物却只有一帧的情况。
  需要确认动效/多帧时，隔约 1 秒截两张再 `diff`。
- `--change` 的默认门槛是 2000 像素；若目标区域本身有动画，需要调高
  `--min-change` 或用 `-R` 缩小观察范围。
- 没有内建交互式选窗口（`-w`）模式，窗口矩形请用 `win list` 获取。
