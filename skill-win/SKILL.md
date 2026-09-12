---
name: dsh-windows-ui
description: Operate the Windows desktop from DSH — click, type, drag, scroll, capture screenshots with coordinate mapping, locate UI elements through the UI Automation tree or on-screen OCR, manage windows, and verify results. Use whenever a task requires driving a Windows GUI app, browser, or game instead of files or CLI, or when the user asks to open/click/type/search something on their screen.
whenToUse: The task needs a graphical interface on this Windows machine — clicking a button that has no CLI, reproducing a GUI-only bug, operating Electron/CEF/canvas apps or games, or verifying that a UI change actually rendered.
---

# Driving the Windows GUI

## Summary

`dsh-ui` (PowerShell) injects real HID events with `SendInput`, captures screenshots 1:1 in
physical pixels, and locates elements through two complementary channels: the **UI Automation
tree** (`find-ax`) and **on-screen OCR** (`find-text`). It reaches surfaces UIA cannot:
Chromium/CEF pages, canvas, games, Electron shells.

**Where the tool lives** — on Windows the macOS `~/.local/bin/dsh-ui` counterpart is
`%USERPROFILE%\.local\bin\dsh-ui.cmd` (i.e. `C:\Users\<you>\.local\bin\`), which this
machine already has on `PATH`; `install.ps1 -Prefix "$env:USERPROFILE\.local"` puts it there.
If `dsh-ui` does not resolve (the host process may have started before the install, so its
`PATH` snapshot is stale), call it by absolute path instead — either
`C:\Users\<you>\.local\bin\dsh-ui.cmd <cmd>` or `powershell -NoProfile -File <repo>\dsh-ui.ps1 <cmd>`.
Running from the repo checkout works too and needs no install.

**Where this skill lives** — DSH only discovers skills under its skill roots, so the
repository copy at `skill-win/SKILL.md` is not enough on its own: install it with
`install.ps1 -WithSkill`, which points
`%USERPROFILE%\.dsh\skills\dsh-windows-ui` at this repository's `skill-win` directory using a
**directory junction**, so edits take effect immediately with no sync step (the macOS
counterpart is `~/.dsh/skills/dsh-macos-ui/`, synced by `make sync-skill`). If a junction
cannot be created (different volume, non-NTFS), the installer falls back to copying and then
the copy must be refreshed with `install.ps1 -WithSkill` after every edit. A junction is
picked up by the catalog without restarting the host; deleting or moving the checkout leaves
a dangling link, so re-run the installer if the repository moves.

**Prefer a non-GUI path when one exists.** CLI tools, HTTP APIs, config files and MCP
servers are faster, more reliable and auditable. Reach for GUI automation only when the
interface genuinely has no programmatic entry point.

## Before the first action

```powershell
dsh-ui guard        # denylist, audit path, dry-run state, OCR mode, DPI awareness
dsh-ui displays     # screen geometry — read this before any click
dsh-ui pos          # where the cursor is now
```

If `dsh-ui` is missing entirely, run it from the checkout
(`powershell -NoProfile -File .\dsh-ui.ps1 <cmd>`) or install it:
`powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Prefix "$env:USERPROFILE\.local"`.
Windows PowerShell 5.1 is the faster host (measured ~2× on `find-text`); `dsh-ui.cmd` picks it
automatically.

There are no macOS-style permission grants. Two Windows realities replace them:

- **DPI**: the tool sets itself PerMonitorV2-aware, so every coordinate it prints and
  accepts is a **physical pixel**. A *DPI-unaware* legacy target sees virtualized
  (logical) coordinates — on a 125 % display the same spot is `(800,400)` to it and
  `(1000,500)` to you. Do not mix the two.
- **UIPI**: synthetic input is dropped by windows whose process runs elevated (as admin).
  If nothing lands on an elevated app, the host must be elevated too. (Not reproduced in
  this repo's verification — treat it as the first hypothesis for a dead click.)

## Command reference

```powershell
# Events
dsh-ui move X Y
dsh-ui click X Y [MS] [--no-activate] [--anyway]
dsh-ui tap   X Y [MS]                   # light tap, 60ms (web/mobile-ish controls)
dsh-ui press X Y [MS]                   # long press, 800ms
dsh-ui dclick X Y
dsh-ui rclick X Y[--anyway]             # NOTE: rclick now also activates first (it used to skip this)
dsh-ui drag X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N]
                        [--momentum F] [--edge-guard N]
dsh-ui scroll N [--drag] [--px-per-notch N]   # positive N scrolls down
dsh-ui type TEXT          # KEYEVENTF_UNICODE: CJK + emoji work, no IME involved
dsh-ui keys TEXT          # ASCII as real virtual key codes (shift applied for caps/symbols)
dsh-ui key ctrl+shift+s   # modifiers: ctrl|cmd, shift, alt|option, win|meta
dsh-ui key down           # named keys: enter tab space esc backspace delete insert
                          #   left up right down home end pageup pagedown
                          #   capslock numlock printscreen pause apps f1..f24
                          #   numpad0-9 multiply add subtract decimal divide
dsh-ui pos

# Screenshots (print the pixel→global mapping)
dsh-ui shot [-D N] [-R X,Y,W,H] [-C] [-c] [-o PATH] [--grid [N]] [--zoom [N]]
dsh-ui displays [--json]

# Locate
dsh-ui find-text "文字" [--all] [--fast] [--click] [--list] [--json] [-D N] [-R ...] [--lang en-US]
dsh-ui find-ax   "文字" [--app 名称] [--pid N] [--all] [--json] [--max N] [--click]
dsh-ui win list [--json] | focus N | maximize N | fullscreen N | move N X Y [W H]
                         | close N | minimize N | restore N
dsh-ui under X Y
dsh-ui foreground [--json]      # who owns the foreground — run this when a click is refused

# Popup menus — navigate with the keyboard, never click a menu item
dsh-ui menu --list X Y          # rclick, then list the items it can see: [n] "text" -> gx gy
dsh-ui menu X Y "项1/项2"        # rclick, walk the path: Down to the item, Right into a
                                # submenu, Enter on the last one; self-checks the highlight
dsh-ui menu --close             # Esc twice, clears a menu left open

# Verify
dsh-ui wait-for --text "文字" [--timeout 20] [--interval 0.6]
dsh-ui wait-for --stable [--timeout 20]
dsh-ui wait-for --change PATH [--min-change 2000] [--threshold 12]
dsh-ui diff A.png B.png [--threshold 12] [-D N] [-R X,Y,W,H]   # -R restricts the comparison

# Utility / safety
dsh-ui clipboard get | set TEXT
dsh-ui batch [-c]           # script from stdin, quotes supported, # comments
dsh-ui --dry <any command>  # print the action, execute nothing
```

Exit codes: `0` ok, `1` not found or timeout, `2` usage error, `3` blocked by the denylist.
**Click semantics changed**: every click command (including `rclick`) verifies the target window
is foreground first, retrying activation up to 3 times; if it still is not, the click is
**not sent** and the command returns `1`. Pass `--anyway` to click regardless (rarely wanted:
that is exactly how clicks get silently eaten).

`find-text --json` prints one machine-readable object
(`{capture:{label,origin,px,pt,scale,path}, needle, ok, hits:[…], matches:[…], clicked}`)
where each hit carries `{text, conf, global, px_center, px_rect}` — `conf` is always `null`
because **Windows OCR exposes no confidence**. It returns 1 when nothing matched, so branch
on the exit code instead of parsing text. `find-ax --json` and `win list --json` exist too.

## Coordinates — the trap

```powershell
$ dsh-ui shot -R 0,0,600,400 --grid 50 --zoom 2
ok path=...-zoom2x-grid.png rect on display #1 px=600x400 pt=480x320 scale=1.25 origin=(0,0) zoom=2x grid=50pt
   mapping: global_x = 0 + px_x/2   global_y = 0 + px_y/2   (图被放大 2x)
```

On Windows a screenshot is **1:1 with physical pixels**, so without `--zoom` the mapping is
simply `global = origin + px`. The `/2` above exists only because the image was upscaled 2×.
`pt=` is the logical size and is **not** a click unit — never click a `pt` number.

Never eyeball a coordinate from a downscaled preview. For small icon-only targets (✕ ⌄ ▶ ⓘ)
capture the region with `--grid` and `--zoom` and read the numbers printed on the image
(red lines label x, blue lines label y, every 5th line is thick) — both axes step from the
top-left, so labels line up with their lines.

Two extra disciplines that came out of a long real session:

* **The attachment is often not the screenshot.** A 1920×1080 capture routinely comes back as a
  1066×600 preview; estimating coordinates off that preview is off by ~1.8×. Either work from
  `-R` + `--zoom` crops that print their own mapping, or scale every preview coordinate by
  `full_width / preview_width` explicitly.
* **The view moves between calls.** Scroll/zoom/caret changes invalidate earlier coordinates: a
  point that hit a control two calls ago can hit a different one now. Re-locate (or re-shoot)
  before the acting call instead of reusing remembered numbers.

## Popup menus

A menu is a separate `#32768` popup window, it is not in the UIA tree, and CJK items come back
from OCR with spaces inserted (`返回` → `派 回`). Clicking an item is also the most fragile
action there is: any focus hiccup lands the click behind the menu. So navigate by keyboard:

```powershell
dsh-ui menu --list 700 400          # 1) see what is actually in the menu
dsh-ui menu 700 400 "选择项/数据"    # 2) walk it: Down xN, Right into a submenu, Enter at the end
dsh-ui menu --close                 # 3) clean up if you aborted
```

`menu` rclicks, locates the popup (window-under-point change → before/after pixel diff → window
class `#32768`), OCRs only inside it, then walks with `down`/`up`/`right`/`enter`, self-checking
the highlight bar and correcting by ±1 when it drifted. Matching ignores whitespace, so OCR's
inserted spaces do not break the lookup. On failure it lists what it did see and presses Esc —
it never fires blind keystrokes.

Known limit: a menu that opens **upward** (taskbar right-click) can evade the diff-based
localisation; the command then says so and falls back to a region OCR, which may mix in text
from behind the menu. In that case run `menu --list` first, then confirm the item text before
navigating, or drive `key down`/`key enter` yourself.

Driving menus by hand is fine when you must: `key down` steps through items (greyed items are
skipped, which is exactly why a pure "count the OCR lines" index drifts), `key right` opens a
submenu, `key enter` commits, `key esc` closes. Submenus close as soon as the mouse leaves them,
so a "hover → screenshot → click the item" sequence usually loses the menu between the two steps.

**A menu is not a palette — know when to stop.** Two different things live behind the same kind
of click:

| | Context menu (Win32 `#32768`) | Icon palette (LabVIEW Functions palette, tool palettes) |
|---|---|---|
| Navigation | keyboard works: `down`/`right`/`enter` | mouse only; keyboard does nothing |
| Sub-items | hover opens the submenu | hover *sometimes* expands; **clicking a category closes the whole palette** |
| OCR | rows of text, one item per row | a grid of icons; OCR returns labels scattered around |
| Verdict | automate it (`dsh-ui menu`) | **stop automating** — 3+ nesting levels, every miss costs a full re-navigation |

When `menu --list` returns a handful of unrelated fragments instead of item rows, you are looking
at a palette, not a menu. Say so and hand that step to the human instead of burning calls.

## Focus, and why clicks disappear

Clicks are delivered to whatever window is foreground, not to the window under the cursor. On a
busy desktop (a browser or chat app stealing focus, an app with a modal dialog) a click can
therefore be swallowed while the command still reports success. The tool now guards this:

* every click command activates the window under the point and **verifies** it became foreground,
  retrying up to 3 times;
* if it still is not foreground the click is **not sent** and the command returns `1`
  (`--anyway` forces it; `--no-activate` only checks);
* watch the exit code, and re-issue after `win focus N` when you get a `1`.

**When the guard refuses, do not reach for `--anyway`.** Ask who owns the foreground instead:

```powershell
$ dsh-ui foreground
前台窗口: Microsoft Edge — "交接文档… "  pid=28356  class=Chrome_WidgetWin_1  pos=(-9,-9)  size=1938x1038
```

`--anyway` sends the click to *that* window (usually harmless, never what you wanted). In a long
LabVIEW session this exact pattern cost ~30 calls: the guard kept refusing, `win focus` kept
"failing", and `foreground` would have answered it in one line — **the DSH chat page itself owned
the foreground**, so every click was aimed at the browser. Two consequences worth internalising:

* **Your own console/browser is a first-class thief.** Each shell command can hand focus to its
  host window; never assume the app you just focused still has it.
* **A modal dialog makes everything else unclickable.** `win list` first; if a dialog is up
  (``连接超时``, ``认证``, save prompts…), dismiss *it* and then act. Click coordinates inside the
  app are irrelevant while it is up.
* Modal dialogs **move** (a LabVIEW "认证" box shifted 14 px between two calls). Re-locate buttons
  by OCR text each time (`find-text "取消" --list`) instead of reusing coordinates.

Two related traps: a modal dialog blocks the app underneath, so list windows and dismiss dialogs
before blaming the click; and a mis-aimed click on empty canvas can pop a **palette** (a floating
window, not a menu) — if the follow-up menu looks wrong, re-locate the target instead of
retrying the click.

## Identifying what an object *is* (before you try to change it)

Custom-drawn apps (LabVIEW, CAD, games, CEF canvases) give the tree nothing useful, so identify
by behaviour, cheapest first:

1. **Hover ~1 s and read the tip strip.** LabVIEW names the object under the cursor
   (`按名称解除捆绑`, `数组至簇转换`…). This single trick untangled a bug that had resisted
   a dozen coordinate-guessed attempts — two visually identical yellow boxes turned out to be
   *different classes*, so every "obvious" fix was aimed at the wrong one.
2. **Right-click and read the menu; the menu is the class oracle.** `取消组合` ⇒ it is a group,
   `打开自定义类型` / `重设自定义类型检查并更新` ⇒ a type-definition instance (its contents are
   **locked** — edit the `.ctl`, not the instance), `簇大小…` ⇒ a cluster constant, `数值选板 /
   数组选板` ⇒ a numeric/array node, `选择项` ⇒ a variable node or cluster-element terminal.
3. **Try to select the inner object.** If clicking always selects one big frame, the thing is a
   container (group / cluster / typedef / subpanel) — treat it as one object, or open its source
   (for a typedef: right-click → open custom type) rather than fighting the selection.

Also: **capture small regions at high zoom**. `shot -R x,y,w,h --zoom 3` comes back roughly 1:1,
so an attachment's pixel coordinates *are* global coordinates; a full-screen shot arrives
downscaled (measured 1920×1080 → 1066×600 ≈ 0.55×) and eyeballing it is off by ~1.8×.

## Which channel to use

| | `find-ax` (UI Automation) | `find-text` (Windows OCR) |
|---|---|---|
| Accuracy | element's real frame — best | text bbox; **Latin is accurate, CJK is not** |
| Coverage | native controls; **not** WinForms Panel/GroupBox/ListBox | anything visible, incl. canvas/CEF |
| Speed | 0.65–1.1 s | 0.9–1.8 s |
| Extra | role, pressable, enabled | — (no confidence) |

Try `find-ax` first, fall back to `find-text`. **Always scope `find-ax` with `--app` or
`--pid`** — unscoped it walks every process. `--app` matches the exe name, the file
description **and window titles**, so `--app "DSH UI Target"` works.

Measured OCR reality on this machine (1920×1080, zh-Hans-CN recognizer):
`Submit`, `TARGET-ALPHA-9931`, `Windows (CRLF)`, `UTF-8` came back perfectly (and the
matching click landed 1 px from the button centre), while `无标题` came back as
`无 》 玺 题` and a 12 px `Clear` as `CI ear`. For CJK targets prefer `find-ax`; if OCR is
the only channel, search a **shorter** keyword and expect character-level noise.

## Standard workflow

1. `dsh-ui displays` — know the geometry and the scale factor.
2. **Maximize the target window before hunting for elements**: `win list`, then
   `win maximize N`. Fewer scroll-and-scan cycles, fewer elements below the fold.
   Window indexes are re-enumerated on every call — always re-list instead of reusing N.
3. Locate: `find-ax "文字" --app <目标>` → else `find-text "文字" -R <region>`.
4. Act: `find-text ... --click`, `find-ax ... --click`, or `click X Y`.
5. Wait for the result with `wait-for --text` / `--stable` / `--change`; never a fixed sleep.
6. Confirm with `shot`, or `diff before.png after.png` when you need to know what changed.
   **"No error" is not success** — decide the success criterion before starting.
7. Clear the text box properly: `key ctrl+a` then `key delete`, then `type`. A web search
   box has been observed to keep its old text with `ctrl+a` + type alone.

A ready-made, half-second end-to-end recipe (verified by the repo's own suite):

```powershell
dsh-ui find-ax "Submit" --pid <pid> --json     # -> matches[0].center = trustworthy click point
dsh-ui click 196 335
dsh-ui wait-for --change before.png --min-change 500
```

## Safety rules

- **There is no approval gate.** The tool executes immediately and the host runs with full
  access. Before any consequential action — sending a message, submitting a form,
  purchasing, changing account/security settings, deleting data — state the exact action
  and get the user's confirmation first. `--dry` shows what would run.
- Every command is appended to `%LOCALAPPDATA%\dsh-ui\audit.log`; cite it when the user asks
  what was done.
- `%LOCALAPPDATA%\dsh-ui\denylist.txt` blocks actions whose target app (process name, app
  description or window title, case-insensitive substring) is listed — password managers by
  default. A block returns exit `3`; report it instead of working around it.
- Never type credentials or secrets. Never automate a denylisted app.
- `--dry` only suppresses side effects: `find-text`, `wait-for`, `diff`, `find-ax`,
  `win list`, `pos`, `under` and `clipboard get` still really read the screen/tree while dry.

## Cost model — when *not* to automate

GUI driving is the right tool for triggering, reading and confirming; it is a poor tool for
**graphical editing**. Measured on a real LabVIEW repair session (roughly 60 tool calls, of which
fewer than a third advanced the task):

| Task | Verdict |
|---|---|
| Launch an app, open a file, press shortcuts, read a dialog, confirm a result | ✅ cheap and reliable |
| Click buttons, toggle checkboxes, pick list rows | ✅ fine once the app is foreground |
| Menus, especially nested ones | ⚠️ use `menu`; hand-rolled hover+click loses the menu |
| Small icon-only targets found by OCR | ⚠️ needs full-resolution crops + `under` to corroborate |
| Diagram/graphics editing (drag to wire, resize handles, canvas tools) | ❌ prefer a file/CLI/API path, or hand it to the human |
| Icon palettes / deeply nested tool palettes | ❌ mouse-only, self-closing — hand it to the human |

Before automating a GUI step, ask whether the same fact is available offline. Decompressing a
file, diffing two versions, or counting strings took seconds and settled a question that had cost
many GUI round-trips; the GUI was only needed to *confirm* it. When a GUI action is unavoidable
but fiddly, do **one** verified step at a time and keep a screenshot trail — and never leave a
half-finished edit unsaved in an app you cannot fully control.

**Mind the app's own state model.** Editing source does not change a *running* program: LabVIEW
keeps executing the loaded copy, so diagram/front-panel edits only take effect after
stop → (save) → run again. Ask "is this app running / does it cache what I just changed?" before
concluding a change failed. Likewise, a saved file's size/ timestamp is the cheapest proof that
an edit was committed (`Get-Item`), and comparing **three copies** (original / test copy /
modified) at the *string* level is usually enough to answer "did we break it, or was it always
like that?" — do that *before* spending GUI calls chasing a suspected regression.

## Known limitations

- **CJK OCR is unreliable** (see the table above). `conf` is `null`; `--fast` is accepted
  but is a no-op. Use `find-text --list` to dump every recognized block before concluding
  anything from a single miss.
- **WinForms Panel/GroupBox/ListBox do not appear in the UIA tree** (measured: 15 elements
  exposed for a window that visually has many more). Locate controls inside such containers
  by OCR or by geometry.
- **`find-text` reads your own conversation.** OCR-ing the display that holds the DSH window
  returns the agent's own messages, so `--click` can target your own chat text. Scope with
  `-R`, or confirm with `under X Y` before clicking.
- **`under X Y` can be wrong** — it is a z-order hit test combined with a UIA hit test, so
  overlapping windows can name the wrong owner. Corroborate with `shot`/`win list` when a
  click matters.
- **Elevated windows ignore synthetic input** (UIPI) — untested here, but it is the first
  thing to check when a click lands nowhere.
- **Locked screen** (⚠ untested): events are expected not to land and screenshots to come
  back black. Ask the user to unlock rather than testing it.
- **Multi-monitor is untested** (only one display available here). Negative coordinates and
  `MOUSEEVENTF_VIRTUALDESK` normalization are implemented; verify before relying on them.
- **`wait-for --stable` times out on any animated UI** (video, spinners, clocks). Use
  `--text` or `--change`.
- **`scroll` converts pixels to wheel notches** (default 100 px/notch, tunable), because
  Windows wheels are line-based; smooth-scrolling UIs may move a different distance than
  requested. If a region refuses to move, try `--drag`, `key pagedown`, or the app's own
  search box.
- **`win fullscreen` fills the monitor** (taskbar area included) — it is not a macOS-style
  native fullscreen space. A second call restores the work-area fit.
- **Short flags are case-sensitive**: `shot -C` composites the cursor into the image while
  `shot -c` puts the image on the clipboard — `-c` is *not* accepted for the cursor flag.
  Command names are case-insensitive (`MOVE` works), sub-commands are not.- **Windows PowerShell 5.1 is ~2× faster than PowerShell 7** for this tool (in-process WinRT
  OCR, faster start): `pos` 571 ms vs 1028 ms, `find-text` 941 ms vs 1798 ms. Both work.
- **Keep the `.ps1` files UTF-8 with BOM.** Windows PowerShell 5.1 decodes BOM-less UTF-8 as
  the system ANSI code page; Chinese comments then swallow an adjacent brace and the script
  fails to parse (hit and diagnosed during this port).

## Verified against

The repo ships `tests/verify-windows.ps1`, which drives a self-built WinForms target
(`tests/ui-target.ps1`) and asserts against **state written by the target itself** — a click
counts only if the button's own handler fired, typed text must match byte-for-byte, a drag
must report the requested displacement. 54 assertions pass on PowerShell 7.6 and Windows
PowerShell 5.1, covering: CLI baseline/exit codes/audit, region capture + grid pixels,
`diff`, all three `wait-for` modes, OCR hit accuracy (button centre vs OCR click: 1 px),
UIA search by pid and by title, `win move/focus/maximize`, real click, `--dry` with no side
effects, CJK+ASCII typing, real key codes, `ctrl+a`/`delete`, clipboard paste, drag
displacement, wheel scrolling, denylist exit 3, per-line batch auditing, and the skill's own
junction install (editing the repository copy is visible through the global path with no sync step).

Docs and source: `docs/REFERENCE-WINDOWS.md` (full reference), `dsh-ui.ps1` (source).
Repo: https://github.com/rayadesune/DSH-computer-use
