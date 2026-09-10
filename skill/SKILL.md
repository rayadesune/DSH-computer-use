---
name: dsh-macos-ui
description: Operate the macOS desktop from DSH — click, type, drag, scroll, capture screenshots with coordinate mapping, locate UI elements by OCR text or the accessibility tree, and verify results. Use whenever a task requires driving a Mac GUI app, browser, or the iPhone Mirroring window instead of files or CLI, or when the user asks to open/click/type/search something on their screen.
whenToUse: The task needs a graphical interface on this Mac — clicking a button that has no CLI, reproducing a GUI-only bug, operating Steam/Electron/CEF apps, driving the iPhone Mirroring window, or verifying that a UI change actually rendered.
---

# Driving the macOS GUI

## Summary

`dsh-ui` at `~/.local/bin/dsh-ui` injects real HID events (`CGEvent`) and captures
screenshots with coordinate mapping. It reaches surfaces AppleScript and the
accessibility tree cannot: Chromium/CEF pages (Steam, Electron apps), canvas,
games. Prefer it over hand-written `osascript` or ad-hoc Swift probes.

**Prefer a non-GUI path when one exists.** CLI tools, HTTP APIs, config files, and
MCP servers are faster, more reliable, and auditable. Reach for GUI automation only
when the interface genuinely has no programmatic entry point.

## Before the first action

```sh
which dsh-ui || echo "MISSING"     # must resolve
dsh-ui guard                        # shows denylist, audit path, dry-run state
dsh-ui displays                     # screen geometry — read this before any click
```

Both host permissions must be granted to the process running DSH (normally
Terminal.app): **Accessibility** for events and AX reads, **Screen Recording** for
`screencapture`. If `shot` fails with "截图失败", the Screen Recording grant is
missing — tell the user instead of retrying.

If `dsh-ui` is missing, rebuild it:

```sh
swiftc -O ~/.local/share/dsh-ui/dsh-ui.swift -o ~/.local/bin/dsh-ui
```

## Command reference

```sh
# Events
dsh-ui move X Y
dsh-ui click X Y [MS] [--no-activate]   # 落点 App 不在前台时先激活再点击
dsh-ui tap   X Y [MS]                   # 轻点，默认 60ms（网页/移动端控件更稳）
dsh-ui press X Y [MS]                   # 长按，默认 800ms（iOS 长按菜单、右键式交互）
dsh-ui dclick X Y | rclick X Y
dsh-ui drag X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N]
                        [--momentum F] [--edge-guard N]
dsh-ui scroll N [--drag]                # --drag：用拖拽模拟（对象忽略合成滚轮时）
dsh-ui type TEXT                 # 中文 OK，绕过输入法
dsh-ui keys TEXT                 # ASCII 逐字符发真实键码（大写/符号自动带 shift）
dsh-ui key cmd+shift+4           # modifiers: cmd shift alt ctrl
dsh-ui pos

# Screenshots (print the pixel→global mapping)
dsh-ui shot [-D N] [-R X,Y,W,H] [-C] [-c] [-o PATH] [--grid [N]] [--zoom [N]]
dsh-ui displays

# Locate
dsh-ui find-text "文字" [--all] [--fast] [--click] [--list] [--json] [-D N] [-R ...]
dsh-ui find-ax  "文字" [--app 名称] [--pid N] [--all]
dsh-ui win list | focus N | maximize N | fullscreen N | move N X Y [W H]

# Verify
dsh-ui wait-for --text "文字" [--timeout 20] [--fast]
dsh-ui wait-for --stable [--timeout 20]
dsh-ui wait-for --change PATH [--min-change 2000]
dsh-ui diff A.png B.png [--threshold 12] [-D N] [-R X,Y,W,H]   # -R 限定比较区域

# Utility / safety
dsh-ui clipboard get | set TEXT
dsh-ui batch [-c]                # script from stdin, quotes supported
dsh-ui --dry <any command>       # print the action, execute nothing
dsh-ui under X Y                 # which app owns that point
```

`find-text --json` prints one machine-readable object
(`{capture:{origin,scale,px,pt}, hits:[{text,conf,global,px_center,px_rect}], matches:[...], clicked:[x,y]}`)
and returns 1 when nothing matched — use it when the next step depends on OCR
content instead of parsing the human output. Combine with `--click` to click the
top match in the same call.

When a click returns exit `3` or seems to land nowhere, run `dsh-ui under X Y` to
see which app actually owns the point — window stacking often differs from what the
last screenshot suggested.

Exit codes: `0` ok, `1` not found or timeout, `2` usage error, `3` blocked by denylist.

## Coordinates — the trap

All `dsh-ui` coordinates are **global, top-left origin**, matching `screencapture -R`
and `CGEvent`. `NSScreen.frame` uses **bottom-left origin**; converting between them
requires the main screen height. Run `dsh-ui displays` and compare `origin_tl` against
`frame_bl` — on a left-side secondary display the difference is exactly the display's
y origin (this project measured `-124` once by getting it wrong).

Pixel-to-click conversion is printed by every `shot`:

```
$ dsh-ui shot -D 2
ok path=... display #2 px=2732x2048 pt=1366x1024 scale=2 origin=(-1366,0)
   mapping: global_x = -1366 + px_x/2   global_y = 0 + px_y/2
```

Never eyeball a coordinate from a downscaled screenshot and click it directly.
Measure pixels in the original PNG, then apply the printed mapping.

**For small icon-only targets (✕ ⌄ ▶ ⓘ …) do not measure by eye at all** — OCR
reads those glyphs unreliably, and a 540-px preview of a 908-px window is where
30 pt errors come from. Capture the region with the grid and the zoom instead:

```sh
dsh-ui shot -R -1010,150,80,260 --grid 50 --zoom 2
# -> path=...-zoom2x-grid.png  mapping: global_x = -1010 + px_x/4 ...
```

The gridded image has the **global coordinates printed on it** (red lines label x,
blue lines label y, every 5th line is thick), and `--zoom` upscales with no
interpolation so pixel edges stay countable. Read the numbers off the image, or
measure pixels in it and divide by the printed scale.

## iPhone Mirroring recipes (measured)

Inside the mirror window there is no accessibility tree for content, so OCR
(`find-text`) is the only reliable channel, and navigation has to go through the
menu bar — in-window gestures are often stolen by the app.

```sh
# home / app switcher / spotlight / control centre
osascript -e 'tell application "System Events" to tell process "iPhone镜像" \
  to click menu item "主屏幕" of menu 1 of menu bar item "显示" of menu bar 1'
```

Valid menu items are `主屏幕`, `App切换器`, `聚焦`, `控制中心`.

| Task | Do this | Not this |
| --- | --- | --- |
| Go home | 显示 → 主屏幕 | swiping up from the bottom edge (the app's own drawer grabs it) |
| Open an app | 显示 → 聚焦, then type the app's **English name** (`shortcut` finds 「捷徑」) | typing the Chinese name (on a Traditional-Chinese phone it turns into a web search) |
| Type ASCII into the phone | `dsh-ui keys "shortcut"` | `dsh-ui type "shortcut"` → types `aaaaaaaa` |
| Scroll a phone list | use the screen's own search box / menus | `scroll` (ignored) or `drag` (works on sheets, dead on some lists) |

More traps that cost real calls:

- **App and UI language can disagree.** The phone was Traditional Chinese
  (Settings 繁体) while the Shortcuts app rendered Simplified (快捷指令) — check the
  actual wording on screen before searching for an action or a button.
- **Control Centre tiles do not accept synthetic clicks** (a screen-record button
  took four clicks with no effect). If the task needs Control Centre, ask the user
  to operate it.
- **The mirror window's bottom edge is a resize handle.** A drag starting within
  ~10 pt of it resizes the window (454×994 → 271×598 was observed). `drag` now
  warns via `--edge-guard` (default 12 pt); re-run `win maximize N` to recover.
- **After any `osascript` menu-bar action the next click may only activate the
  window.** `dsh-ui click` now pre-activates the app under the pointer, so this is
  usually handled — but if a click seems to do nothing, click once more before
  building a theory.

## Standard workflow

1. `dsh-ui displays` — know the geometry.
2. **Maximize the target window before looking for elements.** After opening an app
   run `dsh-ui win list`, then `dsh-ui win maximize N`. A maximized window exposes
   far more of the UI at once, which means fewer scroll-and-scan cycles and fewer
   elements hidden below the fold. Use `win fullscreen N` only when you need every
   pixel; it hides the menu bar and can confuse later coordinate work.
   Apps whose UI is a CEF web view may expose no AX windows at all, so maximize
   cannot apply to them (verified on Steam; DingTalk, also web-based, did expose one).
3. Try `dsh-ui find-ax "文字" --app <目标应用>` first: it returns the element's real
   frame and whether it is pressable. **Always scope it with `--app` or `--pid`** —
   an unscoped search scans every foreground app and matches the agent's own
   conversation text rendered in the Safari window, so the top hit can be a line of
   your own reasoning. Fall back to `dsh-ui find-text "文字"` (OCR) when AX does not
   expose the element — typical for CEF/Electron/web content.
4. `find-text ... --click` or `dsh-ui click X Y`.
5. Wait for the result with `wait-for --text` / `--stable` / `--change`. Do not use
   fixed `sleep`; it is both slower and less reliable.
6. Confirm with `shot`, or `diff before.png after.png` when you need to know exactly
   what changed. **"No error" is not success** — decide the success criterion before
   starting. For anything animated or multi-frame, take two shots ~1 s apart and
   `diff` them: a pipeline once reported a clean success while its output GIF had
   exactly one frame.

Verify an uncertain coordinate before clicking it: `dsh-ui under X Y` names the app
that owns the point. Eyeballing a position from a downscaled screenshot is wrong
often enough that this check is cheaper than a misclick.

**`find-text` reads every window on the display, including your own conversation.**
A scan of the display holding the DSH window returned the agent's own messages and
reasoning as recognized blocks, so `find-text ... --click` can target your own chat
text. Scope with `-R` when the target region is known, or confirm the match with
`dsh-ui under X Y` before clicking. `find-ax` has the same exposure and additionally
needs `--app`/`--pid`.

Timing measured as end-to-end CLI calls: `find-text` ≈0.75 s (OCR ≈0.4 s plus the
capture), `find-ax` 0.24–0.48 s (accessibility-tree walk dominates, not the 10–100 ms a
raw query suggests). The very first `find-text` on a cold machine took 48 s while the
Vision model loaded; whether a reboot re-cold-starts it is untested. **`--fast` mangles
CJK text** — a controlled test returned `*-tstt Way of the Sword (TtyA¥` where the
accurate mode returned the full string at confidence 0.50–1.00, though the Latin part
survived. Use `--fast` only for Latin text or a rough pre-check.

## Batch example

```sh
dsh-ui batch <<'EOF'
find-text "搜索商店" --click
clipboard set 鬼武者
key cmd+v
key return
wait-for --text "鬼武者" --timeout 10
EOF
```

`batch` supports single- and double-quoted arguments, and every sub-command is
written to the audit log individually.

## Safety rules

- **There is no approval gate.** `dsh-ui` executes immediately and the host runs
  with full access. Before any consequential action — sending a message, submitting
  a form, purchasing, changing account/security settings, deleting data — state the
  exact action and get the user's confirmation first. `--dry` shows what would run.
- Every command is appended to `~/.local/state/dsh-ui/audit.log`; cite it when the
  user asks what was done.
- `~/.local/state/dsh-ui/denylist.txt` blocks actions whose click point lands on a
  listed app (password managers by default). A block returns exit `3`; report it
  rather than working around it.
- Never type credentials or secrets. Never automate a denylisted app.

## Known limitations

- **A single OCR miss says nothing about why.** `find-text "新增"` failed once on a
  DingTalk toolbar while `find-ax --app 钉钉` found the `AXButton` immediately. The
  first guess — white text on a coloured button being unreadable — was disproved:
  controlled tests read white-on-blue, -green, and -red down to 13px, with and without
  a `+` icon, at confidence up to 1.00, and read `导出` correctly. Reproduction attempts
  did not trigger the original failure. The same OCR run misread other CJK strings on
  that page (`导出` → `山导出`, `胡瑞峰` → `乙胡瑞峰`), so character-level misrecognition
  is the likeliest cause. Diagnose with `find-text --list`, which dumps every recognized
  block, before drawing any conclusion; prefer `find-ax` whenever the app exposes an
  accessibility tree.
- **Web search boxes may not clear with `cmd+a` alone.** A DingTalk menu search box
  kept its old text after `cmd+a` + type; `cmd+a` + `delete` first, then type, worked.
- **`shot`, `find-text`, and `wait-for` default to display #1 (main).** When the
  target window lives on another display, pass `-D N`; otherwise OCR scans the wrong
  screen and reports "not found" while the text is plainly visible to you.
- **Some apps expose no accessibility tree at all.** With Steam's UI plainly on
  screen, `win list` showed nothing and `find-ax --pid <steam>` found nothing. This is
  per-app, not per-framework: DingTalk, also web-based, exposed both windows and
  elements. Treat an empty AX result as "try OCR", never as "the app is not running";
  find the window with `shot`, then locate elements with `find-text`.
- **Locked screen** (⚠️ untested): events are expected not to land and screenshots to
  come back black; there is no locked-use support. Verifying this would lock the user
  out, so it remains unverified here — ask the user to unlock rather than testing it.
- **`-C` does render the cursor on both displays** — an earlier note here claiming
  otherwise was disproved: 591 changed pixels on the main display and 482 on the
  secondary, both at the cursor position. The original mistake was failing to spot a
  16 px cursor in a 3× downscaled preview.
- **`scroll` emits a full gesture; a single large wheel event is ignored.** The
  original implementation posted one event and a DingTalk navigation panel ignored a
  600 px one entirely. Replaying a real gesture profile — phase sequence
  (began → changed → ended → momentum) with ≤20 px per step — scrolled the same panel
  by 17%. Measured after the fix: DingTalk nav panel 17.18%, DingTalk data table
  8.86%, Safari/WebKit 5.17% (Safari did not move at all before the fix). If a region
  still refuses to move, try `key pagedown` / `key down`, drag its scrollbar, or use
  the app's own search box — and check for a scrollbar before concluding it is fixed.
- `type` fails on native controls that only accept physical key codes (e.g. a
  `<select>` popup) — use `dsh-ui key` with real key codes instead.
- **`type` sends `virtualKey 0` plus a Unicode payload.** macOS Cocoa controls honour
  the payload, so `type` is fine locally and for CJK everywhere. But targets that
  resolve characters from the HID key code + keyboard layout — iPhone Mirroring is
  one — turn every ASCII character into `a`, while CJK still works (the payload is
  the fallback for characters the layout cannot produce). Symptom: `type "shortcut"`
  renders `aaaaaaaa`. Use `keys` (real key codes, shift for capitals/symbols);
  `dsh-ui --dry keys "Ab-1!"` prints the character→key code mapping without typing.
- **`under X Y` can lie, and can return nothing.** It is an accessibility hit test:
  over overlapping windows it named the *desktop* (访达) for a point whose pixels
  belonged to 微信, and at another point that plainly showed a window it answered
  「没有 AX 元素」. Confirm the owner with a `shot`/`win list` when a click matters,
  and prefer `--edge-guard` / pre-activation over blaming the coordinates.
- **`NSWorkspace.frontmostApplication` is unreliable from a one-shot CLI.** Its value
  is refreshed by the run loop and `dsh-ui` never runs one, so it reports stale state
  (it made successful activations look like failures). The tool now reads
  `kAXFocusedApplicationAttribute` and spins a short run loop while waiting; keep that
  in mind before adding any new frontmost logic.
- `wait-for --change` needs `--min-change` raised when the observed region contains
  continuous animation (spinners, clocks, timers).

## Verified against

Steam (CEF: search box, Chinese input, age-gate `<select>`, result navigation),
iPhone Mirroring window (menu-bar navigation, OCR-driven element picking, typing
ASCII via `keys`), macOS menu bar and native dialogs, multi-display coordinate
conversion, Vision OCR Chinese recognition (confidence 1.00).

Later additions verified end to end: `keys "Shortcut-Z9!"` reproduced exactly in
macOS Spotlight (capitals, hyphen and `!` included), `shot --grid/--zoom` grid
labels readable on a 600×360 pt region, `click` pre-activating a background app
that `AXUIElementCopyElementAtPosition` reported as its owner, and
`win focus` + immediate `click` no longer needing a second click.

Docs and source: `docs/REFERENCE.md` (full command reference), `dsh-ui.swift`.
Repo: https://github.com/rayadesune/DSH-computer-use
