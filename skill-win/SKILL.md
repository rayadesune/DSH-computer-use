---
name: dsh-windows-ui
description: Operate the Windows desktop from DSH — click, type, drag, scroll, capture screenshots with coordinate mapping, locate UI elements through the UI Automation tree or on-screen OCR, manage windows, and verify results. Use whenever a task requires driving a Windows GUI app, browser, or game instead of files or CLI, or when the user asks to open/click/type/search something on their screen.
whenToUse: The task needs a graphical interface on this Windows machine — clicking a button that has no CLI, reproducing a GUI-only bug, operating Electron/CEF/canvas apps or games, or verifying that a UI change actually rendered.
---

# Driving the Windows GUI

## Summary

`dsh-ui` (PowerShell, repo root `dsh-ui.ps1`, installed as `dsh-ui.cmd`) injects real HID
events with `SendInput`, captures screenshots 1:1 in physical pixels, and locates elements
through two complementary channels: the **UI Automation tree** (`find-ax`) and **on-screen
OCR** (`find-text`). It reaches surfaces UIA cannot: Chromium/CEF pages, canvas, games,
Electron shells.

**Prefer a non-GUI path when one exists.** CLI tools, HTTP APIs, config files and MCP
servers are faster, more reliable and auditable. Reach for GUI automation only when the
interface genuinely has no programmatic entry point.

## Before the first action

```powershell
dsh-ui guard        # denylist, audit path, dry-run state, OCR mode, DPI awareness
dsh-ui displays     # screen geometry — read this before any click
dsh-ui pos          # where the cursor is now
```

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
dsh-ui click X Y [MS] [--no-activate]   # activates the window under the point first
dsh-ui tap   X Y [MS]                   # light tap, 60ms (web/mobile-ish controls)
dsh-ui press X Y [MS]                   # long press, 800ms
dsh-ui dclick X Y | rclick X Y
dsh-ui drag X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N]
                        [--momentum F] [--edge-guard N]
dsh-ui scroll N [--drag] [--px-per-notch N]   # positive N scrolls down
dsh-ui type TEXT          # KEYEVENTF_UNICODE: CJK + emoji work, no IME involved
dsh-ui keys TEXT          # ASCII as real virtual key codes (shift applied for caps/symbols)
dsh-ui key ctrl+shift+s   # modifiers: ctrl|cmd, shift, alt|option, win|meta
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
- **Windows PowerShell 5.1 is ~2× faster than PowerShell 7** for this tool (in-process WinRT
  OCR, faster start): `pos` 571 ms vs 1028 ms, `find-text` 941 ms vs 1798 ms. Both work.
- **Keep the `.ps1` files UTF-8 with BOM.** Windows PowerShell 5.1 decodes BOM-less UTF-8 as
  the system ANSI code page; Chinese comments then swallow an adjacent brace and the script
  fails to parse (hit and diagnosed during this port).

## Verified against

The repo ships `tests/verify-windows.ps1`, which drives a self-built WinForms target
(`tests/ui-target.ps1`) and asserts against **state written by the target itself** — a click
counts only if the button's own handler fired, typed text must match byte-for-byte, a drag
must report the requested displacement. 41 assertions pass on PowerShell 7.6 and Windows
PowerShell 5.1, covering: CLI baseline/exit codes/audit, region capture + grid pixels,
`diff`, all three `wait-for` modes, OCR hit accuracy (button centre vs OCR click: 1 px),
UIA search by pid and by title, `win move/focus/maximize`, real click, `--dry` with no side
effects, CJK+ASCII typing, real key codes, `ctrl+a`/`delete`, clipboard paste, drag
displacement, wheel scrolling, denylist exit 3, and per-line batch auditing.

Docs and source: `docs/REFERENCE-WINDOWS.md` (full reference), `dsh-ui.ps1` (source).
Repo: https://github.com/rayadesune/DSH-computer-use
