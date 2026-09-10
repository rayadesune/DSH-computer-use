// dsh-ui — macOS 界面自动化工具（事件注入 + 截图 + 定位 + 验证）
//
// 给 DSH 这类 agent 提供一套「看得见、点得准、能验证」的 GUI 操作原语：
//   - 真实 HID 事件（CGEvent），可操作 AppleScript/AX 覆盖不到的地方
//   - 截图自带坐标映射，不用手算多屏偏移
//   - OCR / AX 双通道元素定位
//   - 等待与差异验证，取代固定 sleep
//   - 审计日志、干跑模式、拦截名单
//
// 坐标约定：所有 x y 均为 **全局左上原点**（与 screencapture -R、CGEvent 一致）。
//   NSScreen.frame 用的是左下原点，本工具自动换算，见 `dsh-ui displays`。
//
// 构建：
//   swiftc -O dsh-ui.swift -o ~/.local/bin/dsh-ui
//
// 用法见 --help。

import CoreGraphics
import AppKit
import Foundation
import ImageIO
import Vision

// MARK: - 全局状态

var gDry = false
var gNote = ""

let home = NSHomeDirectory()
let stateDir = "\(home)/.local/state/dsh-ui"
let auditPath = "\(stateDir)/audit.log"
let denyPath = "\(stateDir)/denylist.txt"
let shotDir = "/tmp/dsh-ui-shots"

func fmt(_ v: CGFloat) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%g", Double(v))
}

// MARK: - 审计日志

func writeAudit(_ args: [String], _ code: Int32) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
    var line = "\(f.string(from: Date())) | \(gDry ? "DRY " : "")dsh-ui "
        + args.dropFirst().joined(separator: " ") + " | exit=\(code)"
    if !gNote.isEmpty { line += " | \(gNote)" }
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: auditPath) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: auditPath))
    }
}

// MARK: - 拦截名单

func denyList() -> [String] {
    guard let s = try? String(contentsOfFile: denyPath, encoding: .utf8) else { return [] }
    return s.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// 该坐标下是哪个 App（通过 AX 命中测试）
func appUnder(_ p: CGPoint) -> (bundle: String, name: String)? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success,
          let e = el else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(e, &pid)
    guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    return (app.bundleIdentifier ?? "?", app.localizedName ?? "?")
}

/// 同 appUnder，但返回 App 对象本身（点击前自动激活要用）。
func runningAppUnder(_ p: CGPoint) -> NSRunningApplication? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success,
          let e = el else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(e, &pid)
    return NSRunningApplication(processIdentifier: pid)
}

/// 当前前台 App 的 pid。
/// 必须走 AX 的 kAXFocusedApplication：这是个**实时**查询。
/// NSWorkspace.frontmostApplication 的值靠 run loop 刷新，而 dsh-ui 是一次性 CLI、
/// 从不跑 run loop，读它经常拿到过期值（实测会误报「激活失败」）。
func frontmostPID() -> pid_t? {
    let sys = AXUIElementCreateSystemWide()
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &v) == .success,
          let raw = v else { return nil }
    let el = raw as! AXUIElement
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid > 0 ? pid : nil
}

func isFrontmost(_ app: NSRunningApplication) -> Bool {
    if let pid = frontmostPID() { return pid == app.processIdentifier }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
}

/// 轮询等待 App 真正成为前台。
/// activate() 是异步的：调用后立刻投递的事件会落在「还没成为前台」的窗口上，
/// 被 macOS 当成激活点击吃掉——这就是「第一次点击没反应、要点两次」的根因。
/// 间隔里跑一小段 run loop（而不是纯 usleep），让 AppKit 的状态与事件队列跟上。
@discardableResult
func waitFrontmost(_ app: NSRunningApplication, timeoutMS: Int = 600) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
    repeat {
        if isFrontmost(app) { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return isFrontmost(app)
}

/// 激活 App 并等到它真的到前台（带超时，不会卡死）。
/// macOS 14+ 的 activate() 遵守「防抢焦点」规则，可能被推迟甚至忽略，
/// 所以第一手段失败后再用 AX 的 kAXFrontmost 兜一次——后者对已获辅助功能
/// 授权的进程更可靠（实测微信这类后台 App 只有第二手段才在超时内生效）。
@discardableResult
func activateApp(_ app: NSRunningApplication, timeoutMS: Int = 800) -> Bool {
    if isFrontmost(app) { return true }
    let half = max(150, timeoutMS / 2)
    if #available(macOS 14.0, *) {
        app.activate()
    } else {
        app.activate(options: [.activateIgnoringOtherApps])
    }
    if waitFrontmost(app, timeoutMS: half) { return true }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    return waitFrontmost(app, timeoutMS: half)
}

/// 点击/拖拽前的保险：目标 App 不在前台时先激活，避免第一击被「激活点击」吃掉。
/// 返回 nil 表示无需处理；否则返回给用户的提示文本（成功与否）。
func ensureFrontmostForClick(_ p: CGPoint) -> String? {
    guard let target = runningAppUnder(p), !isFrontmost(target) else { return nil }
    let ok = activateApp(target, timeoutMS: 500)
    let name = target.localizedName ?? "?"
    return ok
        ? "提示: 目标 App「\(name)」先前不在前台，已先激活再点击"
        : "警告: 目标 App「\(name)」未能成为前台（可能被其他窗口抢占），本次点击可能只用于激活窗口"
}

/// 返回非 nil 表示被拦截
func deniedReason(at p: CGPoint) -> String? {
    let list = denyList()
    guard !list.isEmpty, let u = appUnder(p) else { return nil }
    for d in list
    where d.caseInsensitiveCompare(u.bundle) == .orderedSame
        || d.caseInsensitiveCompare(u.name) == .orderedSame {
        return "拦截名单阻止对 \(u.name) (\(u.bundle)) 的操作"
    }
    return nil
}

func guardPoint(_ p: CGPoint) -> Bool {
    if let r = deniedReason(at: p) { print("拒绝执行 — \(r)"); gNote = r; return false }
    return true
}

// MARK: - 基础事件

func point(_ a: [String], _ i: Int) -> CGPoint {
    CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!)
}

func post(_ type: CGEventType, _ p: CGPoint, _ btn: CGMouseButton = .left) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: btn)?
        .post(tap: .cghidEventTap)
}

func keyEvent(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

/// 直接投递 Unicode 字符串（绕过输入法，可直接输入中日韩字符）
func typeString(_ s: String) {
    for ch in s.unicodeScalars {
        var u = UniChar(ch.value)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
        down.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
        up.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

/// 系统光标位置（全局左上原点）。
/// 事件经 CGHIDEventTap 投递到 WindowServer 是异步的：刚 post 完立刻读会拿到**旧位置**，
/// 所以调用方读之前必须让出一点时间，否则 move/click/drag 会打印上一次的坐标。
func currentGlobalCursor() -> CGPoint {
    let m = NSEvent.mouseLocation
    let mainH = NSScreen.screens.first!.frame.height
    return CGPoint(x: m.x, y: mainH - m.y)
}

/// 逐字符发送**真实键码**（含大写/符号的 shift 处理）。
///
/// 为什么需要它：type 走的是「virtualKey 恒为 0 + unicode 字符串」注入。
/// macOS 原生控件认 unicode 载荷，所以本机可用；但像 iPhone 镜像这类
/// 只按 HID 键码查当前布局的目标，会把所有 ASCII 退化成键码 0 对应的 'a'
/// （实测 "shortcut" -> "aaaaaaaa"），而非 ASCII 才回退到 unicode 载荷——
/// 这就是「中文正常、英文全变 a」的成因。keys 用真实键码绕开这个坑。
struct KeyStroke { let code: CGKeyCode; let shift: Bool }

let shiftPairs: [Character: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
    "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
    ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
]

func strokeFor(_ ch: Character) -> KeyStroke? {
    switch ch {
    case " ":  return KeyStroke(code: keyMap["space"]!, shift: false)
    case "\n": return KeyStroke(code: keyMap["return"]!, shift: false)
    case "\t": return KeyStroke(code: keyMap["tab"]!, shift: false)
    default: break
    }
    if let base = shiftPairs[ch], let code = keyMap[base] { return KeyStroke(code: code, shift: true) }
    if ch.isUppercase, let code = keyMap[String(ch).lowercased()] { return KeyStroke(code: code, shift: true) }
    if let code = keyMap[String(ch)] { return KeyStroke(code: code, shift: false) }
    return nil
}

@discardableResult
func typeKeys(_ s: String) -> (sent: Int, skipped: [Character]) {
    var sent = 0
    var skipped: [Character] = []
    let shiftCode: CGKeyCode = 56          // kVK_Shift
    for ch in s {
        guard let st = strokeFor(ch) else { skipped.append(ch); continue }
        if st.shift { keyEvent(shiftCode, true, [.maskShift]); usleep(4_000) }
        keyEvent(st.code, true, st.shift ? [.maskShift] : [])
        usleep(8_000)
        keyEvent(st.code, false, st.shift ? [.maskShift] : [])
        if st.shift { usleep(4_000); keyEvent(shiftCode, false, []) }
        usleep(12_000)
        sent += 1
    }
    return (sent, skipped)
}

func printCursor(settleUS: UInt32 = 25_000) {
    if settleUS > 0 { usleep(settleUS) }
    let g = currentGlobalCursor()
    print("ok cursor=(\(Int(g.x)),\(Int(g.y))) top-left-coords")
}

// MARK: - 窗口几何辅助（拖拽护栏）

/// 找出「盖住该点」的最小窗口（AX 窗口坐标与 dsh-ui 同为全局左上原点）。
/// 用于拖拽前的边缘护栏：起手点贴近窗口边缘时，macOS 会把拖拽当成窗口缩放/移动。
func windowUnder(_ p: CGPoint) -> (app: String, rect: CGRect)? {
    var best: (String, CGRect)? = nil
    for a in NSWorkspace.shared.runningApplications
    where a.activationPolicy == .regular && !a.isTerminated {
        for w in axWindows(a) {
            guard let wp = axPoint(w, kAXPositionAttribute),
                  let ws = axSize(w, kAXSizeAttribute),
                  ws.width > 1, ws.height > 1 else { continue }
            let r = CGRect(origin: wp, size: ws)
            guard r.contains(p) else { continue }
            if best == nil || r.width * r.height < best!.1.width * best!.1.height {
                best = (a.localizedName ?? "?", r)
            }
        }
    }
    guard let b = best else { return nil }
    return (b.0, b.1)
}

/// 起手点距所属窗口边缘过近时返回警告文本（nil = 安全）。
func edgeWarning(_ p: CGPoint, margin: CGFloat) -> String? {
    guard margin > 0, let w = windowUnder(p) else { return nil }
    let d = min(min(p.x - w.rect.minX, w.rect.maxX - p.x),
                min(p.y - w.rect.minY, w.rect.maxY - p.y))
    guard d < margin else { return nil }
    return "起手点距窗口「\(w.app)」边缘仅 \(Int(d))pt（阈值 \(Int(margin))pt）："
        + "该拖拽可能被 macOS 当成窗口缩放而非内容拖拽；建议起点内移，或显式加 --edge-guard 0"
}

/// 统一的「按下-保持-抬起」，是 click / tap / press 的共用实现。
func tapAt(_ p: CGPoint, holdMS: Int) {
    post(.mouseMoved, p)
    usleep(30_000)
    post(.leftMouseDown, p)
    usleep(UInt32(max(1, holdMS)) * 1000)
    post(.leftMouseUp, p)
}

/// 通用拖拽：起手停顿 + 分段移动 + 可选惯性尾巴。
func dragGesture(from s: CGPoint, to e: CGPoint,
                 settleMS: Int, holdMS: Int, moveMS: Int, steps: Int,
                 momentum: Double = 0) {
    let n = max(1, steps)
    post(.mouseMoved, s)
    usleep(UInt32(max(0, settleMS)) * 1000)
    post(.leftMouseDown, s)
    usleep(UInt32(max(0, holdMS)) * 1000)
    let per = UInt32(max(2, moveMS / n)) * 1000
    for i in 1...n {
        let t = Double(i) / Double(n)
        post(.leftMouseDragged, CGPoint(x: s.x + (e.x - s.x) * t, y: s.y + (e.y - s.y) * t))
        usleep(per)
    }
    post(.leftMouseUp, e)
    // 惯性：抬手后继续投递若干次同向拖拽事件（部分滚动视图只认这个才真正滚动）
    if momentum > 0 {
        let dx = e.x - s.x, dy = e.y - s.y
        for k in 1...6 {
            let f = 1.0 + momentum * Double(k) / 6.0
            post(.leftMouseDragged, CGPoint(x: e.x + dx * Double(k) * 0.06 * f,
                                            y: e.y + dy * Double(k) * 0.06 * f))
            usleep(12_000)
        }
    }
}

// MARK: - 显示器几何

struct Disp {
    let index: Int
    let tlOrigin: CGPoint
    let blFrame: NSRect
    let visibleBL: NSRect   // NSScreen.visibleFrame（左下原点，已排除菜单栏/Dock）
    let scale: CGFloat
    let mainH: CGFloat
    let mainMenuInset: CGFloat   // 主屏顶部菜单栏高度
    var ptSize: CGSize { blFrame.size }
    var pxSize: CGSize { CGSize(width: blFrame.width * scale, height: blFrame.height * scale) }
    /// 可见区域，换算成左上原点。
    /// 非活动屏幕的 visibleFrame 不扣菜单栏（macOS 只在活动屏上扣），
    /// 但窗口管理器仍按菜单栏高度裁剪，所以这里用主屏的菜单栏高度补齐。
    var visibleTL: CGRect {
        var y = mainH - (visibleBL.origin.y + visibleBL.height)
        var h = visibleBL.height
        if h == blFrame.height, mainMenuInset > 0 {
            y += mainMenuInset
            h -= mainMenuInset
        }
        return CGRect(x: visibleBL.origin.x, y: y, width: visibleBL.width, height: h)
    }
    func contains(_ p: CGPoint) -> Bool {
        p.x >= tlOrigin.x && p.x < tlOrigin.x + ptSize.width &&
        p.y >= tlOrigin.y && p.y < tlOrigin.y + ptSize.height
    }
}

func displays() -> [Disp] {
    let screens = NSScreen.screens
    guard let mainH = screens.first?.frame.height else { return [] }
    let mainMenuInset = mainH - (screens.first?.visibleFrame.height ?? mainH)
    return screens.enumerated().map { (i, s) in
        let f = s.frame
        return Disp(index: i + 1,
                    tlOrigin: CGPoint(x: f.origin.x, y: mainH - (f.origin.y + f.height)),
                    blFrame: f,
                    visibleBL: s.visibleFrame,
                    scale: s.backingScaleFactor,
                    mainH: mainH,
                    mainMenuInset: mainMenuInset)
    }
}

func disp(index n: Int) -> Disp? { displays().first { $0.index == n } }

// MARK: - 进程 / 图像工具

@discardableResult
func run(_ launchPath: String, _ argv: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = argv
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { print("执行失败: \(error.localizedDescription)"); return 127 }
    p.waitUntilExit()
    return p.terminationStatus
}

func imagePixelSize(_ path: String) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

func rgbaBuffer(_ path: String) -> (w: Int, h: Int, buf: [UInt8])? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

// MARK: - 图像派生（网格标尺 / 放大）

/// 在扩展名前插入后缀：a/b.png + "-grid" -> a/b-grid.png
func derivedPath(_ path: String, _ suffix: String) -> String {
    let ns = path as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? base + suffix : base + suffix + "." + ext
}

@discardableResult
func writePNG(_ img: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

func loadCG(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// 放大倍数（interpolation=none）——只为了让 agent 逐个像素量取小图标，不做美化。
func zoomImage(path: String, factor: CGFloat, out: String) -> Bool {
    guard factor > 1, let cg = loadCG(path) else { return false }
    let w = Int(CGFloat(cg.width) * factor), h = Int(CGFloat(cg.height) * factor)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.interpolationQuality = .none
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    guard let img = ctx.makeImage() else { return false }
    return writePNG(img, to: out)
}

/// 在截图上叠加**带全局坐标数字**的标尺网格，消除「从缩放预览目测坐标」这类错误。
func drawGrid(path: String, origin: CGPoint, scale: CGFloat, step: CGFloat, out: String) -> Bool {
    guard step > 0, let cg = loadCG(path) else { return false }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

    let pxStep = step * scale
    guard pxStep >= 6 else { print("  警告: 网格步长过小（\(Int(pxStep))px），已跳过"); return false }

    func label(_ text: String, _ x: CGFloat, _ y: CGFloat) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0.65),
        ]
        NSString(string: text).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    // 竖线：标注全局 x
    var px: CGFloat = 0
    var k = 0
    while px <= CGFloat(w) {
        let gx = Int((origin.x + px / scale).rounded())
        ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.15, alpha: k % 5 == 0 ? 0.95 : 0.5))
        ctx.setLineWidth(k % 5 == 0 ? 1.5 : 1)
        ctx.move(to: CGPoint(x: px + 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: px + 0.5, y: CGFloat(h)))
        ctx.strokePath()
        label("\(gx)", px + 3, CGFloat(h) - 13)
        px += pxStep; k += 1
    }
    // 横线：标注全局 y
    var py: CGFloat = 0
    k = 0
    while py <= CGFloat(h) {
        let gy = Int((origin.y + py / scale).rounded())
        ctx.setStrokeColor(CGColor(red: 0.15, green: 0.55, blue: 1, alpha: k % 5 == 0 ? 0.95 : 0.5))
        ctx.setLineWidth(k % 5 == 0 ? 1.5 : 1)
        ctx.move(to: CGPoint(x: 0, y: py + 0.5))
        ctx.addLine(to: CGPoint(x: CGFloat(w), y: py + 0.5))
        ctx.strokePath()
        label("\(gy)", 3, CGFloat(h) - py - 12)
        py += pxStep; k += 1
    }
    guard let img = ctx.makeImage() else { return false }
    return writePNG(img, to: out)
}

// MARK: - 截图

struct Capture {
    let path: String
    let origin: CGPoint
    let scale: CGFloat
    let ptSize: CGSize
    let pxSize: CGSize
    let label: String
}

func capture(display: Int?, rect: CGRect?, withCursor: Bool = false, outPath: String? = nil) -> Capture? {
    let disps = displays()
    var argv: [String] = ["-x"]
    if withCursor { argv.append("-C") }
    if let d = display { argv.append(contentsOf: ["-D", String(d)]) }
    if let r = rect {
        argv.append(contentsOf: ["-R",
            "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"])
    }
    let path: String
    if let o = outPath {
        path = (o as NSString).expandingTildeInPath
    } else {
        try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
        path = "\(shotDir)/shot-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 100...999)).png"
    }
    try? FileManager.default.removeItem(atPath: path)
    argv.append(path)
    guard run("/usr/sbin/screencapture", argv) == 0,
          FileManager.default.fileExists(atPath: path),
          let (pw, ph) = imagePixelSize(path) else { return nil }

    var origin = CGPoint.zero
    var scale: CGFloat = 1
    var ptSize = CGSize.zero
    var label = ""
    if let r = rect {
        origin = r.origin; ptSize = r.size
        if let d = disps.first(where: { $0.contains(r.origin) }) {
            scale = d.scale
            label = "rect on display #\(d.index)"
        } else {
            label = "rect (未匹配到屏幕)"
        }
    } else {
        let d = disp(index: display ?? 1) ?? disps[0]
        origin = d.tlOrigin; scale = d.scale; ptSize = d.ptSize
        label = "display #\(d.index)" + (d.index == 1 ? " (main)" : "")
    }
    return Capture(path: path, origin: origin, scale: scale, ptSize: ptSize,
                   pxSize: CGSize(width: pw, height: ph), label: label)
}

/// 像素坐标 -> 全局点击坐标
func toGlobal(_ p: CGPoint, _ c: Capture) -> CGPoint {
    CGPoint(x: c.origin.x + p.x / c.scale, y: c.origin.y + p.y / c.scale)
}

func parseRect(_ s: String) -> CGRect? {
    let parts = s.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

// MARK: - OCR

struct OcrHit {
    let text: String
    let conf: Float
    let pxRect: CGRect
}

func ocr(_ path: String, fast: Bool) -> [OcrHit]? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let W = Double(cg.width), H = Double(cg.height)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = fast ? .fast : .accurate
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { return nil }
    guard let obs = req.results else { return nil }
    var hits: [OcrHit] = []
    for o in obs {
        guard let c = o.topCandidates(1).first else { continue }
        let b = o.boundingBox          // 归一化，左下原点
        let r = CGRect(x: b.origin.x * W,
                       y: (1 - b.origin.y - b.height) * H,   // 转左上原点像素
                       width: b.width * W,
                       height: b.height * H)
        hits.append(OcrHit(text: c.string, conf: c.confidence, pxRect: r))
    }
    return hits
}

// MARK: - Accessibility

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}

func axString(_ e: AXUIElement, _ k: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func axPoint(_ e: AXUIElement, _ k: String) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success,
          let val = v else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(val as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func axSize(_ e: AXUIElement, _ k: String) -> CGSize? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success,
          let val = v else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(val as! AXValue, .cgSize, &s) else { return nil }
    return s
}

func axActions(_ e: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyActionNames(e, &v) == .success,
          let arr = v as? [String] else { return [] }
    return arr
}

func axWindows(_ app: NSRunningApplication) -> [AXUIElement] {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
          let ws = v as? [AXUIElement] else { return [] }
    return ws
}

struct AxHit {
    let role: String
    let title: String
    let pos: CGPoint
    let size: CGSize
    let pressable: Bool
    let app: String
    let bundle: String
    var center: CGPoint { CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2) }
}

func axSearch(app: NSRunningApplication, needle: String, limit: Int = 20, maxDepth: Int = 30) -> [AxHit] {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let lower = needle.lowercased()
    var hits: [AxHit] = []
    let appName = app.localizedName ?? "?"
    let bundle = app.bundleIdentifier ?? "?"
    func walk(_ e: AXUIElement, _ depth: Int) {
        if hits.count >= limit || depth > maxDepth { return }
        var text = ""
        for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                  kAXHelpAttribute, kAXRoleDescriptionAttribute] {
            if let s = axString(e, k), !s.isEmpty { text += s + "\u{1}" }
        }
        if !text.isEmpty, text.lowercased().contains(lower),
           let p = axPoint(e, kAXPositionAttribute),
           let s = axSize(e, kAXSizeAttribute), s.width > 0, s.height > 0 {
            hits.append(AxHit(role: axString(e, kAXRoleAttribute) ?? "?",
                              title: axString(e, kAXTitleAttribute) ?? "",
                              pos: p, size: s,
                              pressable: axActions(e).contains(kAXPressAction as String),
                              app: appName, bundle: bundle))
        }
        for c in axChildren(e) { walk(c, depth + 1) }
    }
    walk(root, 0)
    return hits
}

// MARK: - 键码表

let keyMap: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, "/": 44,
    ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "esc": 53, "escape": 53,
    "delete": 51, "backspace": 51, "forwarddelete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

let modifierMap: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "shift": .maskShift,
    "alt": .maskAlternate, "option": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl,
]

// MARK: - 帮助

let helpText = """
dsh-ui — macOS 界面自动化（坐标 = 全局左上原点）

【鼠标 / 键盘】
  move   X Y                移动光标
  click  X Y [MS] [--no-activate]
                            左键单击（可指定按下时长，默认 30ms）。
                            若落点所属 App 不在前台，会**先激活它再点击**，
                            避免 macOS 把第一击当成「激活窗口」吃掉；
                            用 --no-activate 关闭该行为（不想被抢焦点时）
  tap    X Y [MS]           轻点（默认 60ms，比 click 稍慢，适合网页/移动端控件）
  press  X Y [MS]           长按（默认 800ms，用于 iOS/右键菜单这类长按交互）
  dclick X Y                左键双击
  rclick X Y                右键单击
  drag   X1 Y1 X2 Y2 [选项] 拖拽。选项：
         --ms N             总移动时长（默认 216）
         --steps N          分段数（默认 12）
         --hold N           按下后停顿再移动（默认 80）
         --settle N         起手前停顿（默认 80）
         --momentum F       抬手后的惯性尾巴（默认 0，滚动视图可试 1.0）
         --edge-guard N     起手点距窗口边缘 <N pt 时告警（默认 12，0=关闭）
  scroll N [--drag]         垂直滚动 N 像素；--drag 改用拖拽模拟
                            （部分界面如 iPhone 镜像完全忽略合成滚轮事件）
  type   TEXT               输入文本（支持中文，绕过输入法）
                            注意：部分目标（如 iPhone 镜像）只认真实键码，
                            ASCII 可能退化成 aaaa，此时改用 keys
  keys   TEXT               ASCII 逐字符发真实键码（配 shift 处理大写与符号）
  key    KEY                按键，支持 cmd+shift+4
  pos                       打印光标位置

【截图】
  shot [-D N] [-R X,Y,W,H] [-C] [-c] [-o PATH] [--grid [N]] [--zoom [N]]
                            默认输出原图；--grid 叠加**带全局坐标数字**的标尺网格，
                            --zoom 无插值放大 N 倍（默认 2），便于逐个像素量取小图标。
                            派生图写在原图旁（-grid/-zoomNx 后缀），原图保留。
  displays                  屏幕坐标对照表

【定位】
  find-text "文字" [--all] [--fast] [--click] [--list] [-D N] [-R X,Y,W,H]
                            OCR 找文字，输出可直接点击的全局坐标
  find-ax  "文字" [--app 名称] [--pid N] [--all]
                            Accessibility 树里找元素（精度更高，原生 App 优先）
                            务必用 --app/--pid 限定目标，否则会命中其他窗口
  win list | focus N | maximize N | fullscreen N | move N X Y [W H]
                            列出 / 聚焦 / 移动窗口

【验证】
  wait-for --text "文字" [--timeout 20] [--interval 0.6] [-D N] [-R ...]
  wait-for --stable      [--timeout 20]
  wait-for --change PATH [--timeout 20]
  diff A.png B.png [--threshold 12] [-D N] [-R ...]

【其他】
  clipboard get | set TEXT
  batch [-c]                从 stdin 读脚本逐条执行（-c 出错继续）
  guard                     查看拦截名单与审计日志路径
  under  X Y                该坐标下是哪个 App（排查拦截/点击落空）

【全局开关】
  --dry                     干跑：只打印将要执行的动作，不真的操作

示例:
  dsh-ui shot -D 2
  dsh-ui find-text "哔哩哔哩" --click
  dsh-ui find-ax "搜索商店"
  dsh-ui win list
  dsh-ui wait-for --text "首页" --timeout 15
  dsh-ui diff a.png b.png
  dsh-ui --dry click 100 200

状态文件:
  审计日志  ~/.local/state/dsh-ui/audit.log
  拦截名单  ~/.local/state/dsh-ui/denylist.txt
"""

// MARK: - 命令实现

func doShot(_ args: [String]) -> Int32 {
    var display: Int? = nil
    var rect: CGRect? = nil
    var withCursor = false
    var toClipboard = false
    var outPath: String? = nil
    var gridStep: CGFloat? = nil
    var zoomFactor: CGFloat = 1

    var i = 2
    while i < args.count {
        switch args[i] {
        case "-D":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { print("用法: shot -D N"); return 2 }
            display = n; i += 2
        case "-R":
            guard i + 1 < args.count, let r = parseRect(args[i + 1]) else {
                print("-R 需要 X,Y,W,H"); return 2
            }
            rect = r; i += 2
        case "-C": withCursor = true; i += 1
        case "-c": toClipboard = true; i += 1
        case "-o":
            guard i + 1 < args.count else { print("用法: shot -o PATH"); return 2 }
            outPath = args[i + 1]; i += 2
        case "--grid":
            gridStep = 50
            if i + 1 < args.count, let v = Double(args[i + 1]), v > 0 { gridStep = CGFloat(v); i += 2 }
            else { i += 1 }
        case "--zoom":
            zoomFactor = 2
            if i + 1 < args.count, let v = Double(args[i + 1]), v > 1 { zoomFactor = CGFloat(v); i += 2 }
            else { i += 1 }
        default: print("未知选项: \(args[i])"); return 2
        }
    }
    if let d = display, disp(index: d) == nil {
        print("没有第 \(d) 块屏；可用: \(displays().map { $0.index })"); return 2
    }

    // --dry 语义：只描述、不执行。截图需要「屏幕录制」权限，
    // CI 这类没有授权的环境必须能安全地干跑，否则没法做冒烟测试。
    if gDry {
        var d = "dry: would shot"
        if let n = display { d += " -D \(n)" }
        if let r = rect {
            d += " -R \(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"
        }
        if withCursor { d += " -C" }
        if toClipboard { d += " -c" }
        if let o = outPath { d += " -o \(o)" }
        if let g = gridStep { d += " --grid \(fmt(g))" }
        if zoomFactor > 1 { d += " --zoom \(fmt(zoomFactor))" }
        print(d)
        return 0
    }

    if toClipboard {
        var argv: [String] = ["-x", "-c"]
        if let d = display { argv.append(contentsOf: ["-D", String(d)]) }
        if let r = rect {
            argv.append(contentsOf: ["-R", "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"])
        }
        guard run("/usr/sbin/screencapture", argv) == 0 else { print("截图失败"); return 1 }
        print("ok clipboard"); return 0
    }

    guard let c = capture(display: display, rect: rect, withCursor: withCursor, outPath: outPath) else {
        print("截图失败 — 检查「屏幕录制」权限"); return 1
    }

    // 派生图：放大 -> 网格（顺序固定，网格坐标按放大后的像素密度标注）
    var finalPath = c.path
    var effScale = c.scale
    if zoomFactor > 1 {
        let z = derivedPath(c.path, "-zoom\(Int(zoomFactor))x")
        if zoomImage(path: c.path, factor: zoomFactor, out: z) {
            finalPath = z; effScale = c.scale * zoomFactor
        } else { print("  警告: 放大失败，已保留原图") }
    }
    if let g = gridStep {
        let gp = derivedPath(finalPath, "-grid")
        if drawGrid(path: finalPath, origin: c.origin, scale: effScale, step: g, out: gp) {
            finalPath = gp
        } else { print("  警告: 网格绘制失败，已保留未叠加图") }
    }

    print("ok path=\(finalPath) \(c.label) px=\(Int(c.pxSize.width))x\(Int(c.pxSize.height))"
        + " pt=\(Int(c.ptSize.width))x\(Int(c.ptSize.height))"
        + " scale=\(fmt(c.scale)) origin=(\(Int(c.origin.x)),\(Int(c.origin.y)))"
        + (zoomFactor > 1 ? " zoom=\(fmt(zoomFactor))x" : "")
        + (gridStep != nil ? " grid=\(fmt(gridStep!))pt" : ""))
    print("   mapping: global_x = \(Int(c.origin.x)) + px_x/\(fmt(effScale))"
        + "   global_y = \(Int(c.origin.y)) + px_y/\(fmt(effScale))")
    if finalPath != c.path { print("   原图: \(c.path)") }
    if gridStep != nil {
        print("   网格已把**全局左上坐标**写在图上：红线标 x，蓝线标 y，粗线是 5 格整数倍")
    }
    return 0
}

func doFindText(_ args: [String]) -> Int32 {
    guard args.count >= 3 else { print("用法: find-text \"文字\" [--all] [--fast] [--click] [--list]"); return 2 }
    let needle = args[2]
    var all = false, fast = false, doClick = false, listAll = false, jsonOut = false
    var display: Int? = nil, rect: CGRect? = nil
    var i = 3
    while i < args.count {
        switch args[i] {
        case "--all": all = true; i += 1
        case "--fast": fast = true; i += 1
        case "--click": doClick = true; i += 1
        case "--list": listAll = true; i += 1
        case "--json": jsonOut = true; i += 1
        case "-D":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { return 2 }
            display = n; i += 2
        case "-R":
            guard i + 1 < args.count, let r = parseRect(args[i + 1]) else { return 2 }
            rect = r; i += 2
        default: print("未知选项: \(args[i])"); return 2
        }
    }

    guard let c = capture(display: display, rect: rect) else {
        print("截图失败 — 检查「屏幕录制」权限"); return 1
    }
    guard let hits = ocr(c.path, fast: fast) else { print("OCR 失败"); return 1 }

    let matches = hits.filter { $0.text.range(of: needle, options: .caseInsensitive) != nil }

    // --json：把整块结果交给上层脚本判断（配合 --click 仍会执行点击）
    if jsonOut {
        func enc(_ h: OcrHit) -> [String: Any] {
            let g = toGlobal(CGPoint(x: h.pxRect.midX, y: h.pxRect.midY), c)
            return ["text": h.text,
                    "conf": Double(h.conf),
                    "px_center": [Int(h.pxRect.midX), Int(h.pxRect.midY)],
                    "global": [Int(g.x.rounded()), Int(g.y.rounded())],
                    "px_rect": [Int(h.pxRect.origin.x), Int(h.pxRect.origin.y),
                                Int(h.pxRect.width), Int(h.pxRect.height)]]
        }
        var clicked: [Int]? = nil
        if doClick, let first = matches.first {
            let g = toGlobal(CGPoint(x: first.pxRect.midX, y: first.pxRect.midY), c)
            if gDry {
                clicked = [Int(g.x), Int(g.y)]
            } else if guardPoint(g) {
                let p = CGPoint(x: g.x.rounded(), y: g.y.rounded())
                tapAt(p, holdMS: 30)
                clicked = [Int(p.x), Int(p.y)]
            }
        }
        let root: [String: Any] = [
            "ok": !matches.isEmpty,
            "needle": needle,
            "capture": ["path": c.path, "label": c.label,
                        "origin": [Int(c.origin.x), Int(c.origin.y)],
                        "scale": Double(c.scale),
                        "px": [Int(c.pxSize.width), Int(c.pxSize.height)],
                        "pt": [Int(c.ptSize.width), Int(c.ptSize.height)]],
            "hits": hits.map(enc),
            "matches": matches.map(enc),
            "clicked": clicked as Any,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        } else {
            print("{\"ok\":false,\"error\":\"json 序列化失败\"}")
        }
        return matches.isEmpty ? 1 : 0
    }

    // --list：只转储识别结果，不做匹配（诊断用）
    if listAll {
        print("ok 识别到 \(hits.count) 个文本块 (\(c.label))")
        for (n, h) in hits.enumerated() {
            let g = toGlobal(CGPoint(x: h.pxRect.midX, y: h.pxRect.midY), c)
            print("  [\(n)] \"\(h.text)\" conf=\(String(format: "%.2f", h.conf))"
                + " -> click \(Int(g.x)) \(Int(g.y))")
        }
        return 0
    }

    if matches.isEmpty {
        print("未找到「\(needle)」— 共识别 \(hits.count) 个文本块，图 \(Int(c.pxSize.width))x\(Int(c.pxSize.height))px")
        if hits.count > 0 {
            // 全部列出：命中失败时最可能的原因是字符级误识，必须看到原文才能判断
            print("  识别到的文字: " + hits.map { $0.text }.joined(separator: " / "))
            print("  提示: 若目标在列表里但写法不同（如误识），改用更短的关键词，或用 find-ax 换通道")
        }
        return 1
    }
    print("ok \"\(needle)\" 匹配 \(matches.count) 处 (\(c.label), mapping: global = (\(Int(c.origin.x)),\(Int(c.origin.y))) + px/\(fmt(c.scale)))")
    let shown = all ? matches : Array(matches.prefix(1))
    for (n, m) in shown.enumerated() {
        let center = CGPoint(x: m.pxRect.midX, y: m.pxRect.midY)
        let g = toGlobal(center, c)
        print("  [\(n)] \"\(m.text)\" conf=\(String(format: "%.2f", m.conf))"
            + " px_center=(\(Int(center.x)),\(Int(center.y)))"
            + " -> dsh-ui click \(Int(g.x)) \(Int(g.y))")
    }
    if doClick, let first = shown.first {
        let g = toGlobal(CGPoint(x: first.pxRect.midX, y: first.pxRect.midY), c)
        if gDry { print("dry: would click \(Int(g.x)) \(Int(g.y))"); return 0 }
        guard guardPoint(g) else { return 3 }
        let p = CGPoint(x: g.x.rounded(), y: g.y.rounded())
        post(.mouseMoved, p); usleep(60_000)
        post(.leftMouseDown, p); usleep(30_000); post(.leftMouseUp, p)
        print("  已点击 (\(Int(p.x)),\(Int(p.y)))")
    }
    return 0
}

func doFindAx(_ args: [String]) -> Int32 {
    guard args.count >= 3 else { print("用法: find-ax \"文字\" [--app 名称] [--pid N] [--all]"); return 2 }
    let needle = args[2]
    var all = false, pid: pid_t? = nil
    var appFilter: String? = nil
    var i = 3
    while i < args.count {
        switch args[i] {
        case "--all": all = true; i += 1
        case "--pid":
            guard i + 1 < args.count, let n = Int32(args[i + 1]) else { return 2 }
            pid = n; i += 2
        case "--app":
            guard i + 1 < args.count else { return 2 }
            appFilter = args[i + 1].lowercased(); i += 2
        default: print("未知选项: \(args[i])"); return 2
        }
    }
    var apps: [NSRunningApplication]
    if let p = pid {
        guard let a = NSRunningApplication(processIdentifier: p) else { print("没有 pid=\(p) 的进程"); return 1 }
        apps = [a]
    } else {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }
    if let f = appFilter {
        apps = apps.filter {
            ($0.localizedName ?? "").lowercased().contains(f)
                || ($0.bundleIdentifier ?? "").lowercased().contains(f)
        }
        if apps.isEmpty { print("没有名称匹配「\(appFilter ?? "")」的 App"); return 1 }
    }
    var hits: [AxHit] = []
    for a in apps { hits += axSearch(app: a, needle: needle) }
    if hits.isEmpty {
        print("AX 树中未找到「\(needle)」（已扫描 \(apps.count) 个 App）")
        return 1
    }
    print("ok AX 匹配 \(hits.count) 处")
    let shown = all ? hits : Array(hits.prefix(1))
    for (n, h) in shown.enumerated() {
        print("  [\(n)] \(h.role) title=\"\(h.title)\" app=\(h.app)"
            + " pos=(\(Int(h.pos.x)),\(Int(h.pos.y))) size=\(Int(h.size.width))x\(Int(h.size.height))"
            + " pressable=\(h.pressable) -> dsh-ui click \(Int(h.center.x)) \(Int(h.center.y))")
    }
    return 0
}

func doWin(_ args: [String]) -> Int32 {
    guard args.count >= 3 else { print("用法: win list | focus N | maximize N | fullscreen N | move N X Y [W H]"); return 2 }
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated }

    switch args[2] {
    case "list":
        var idx = 0
        for a in apps {
            for w in axWindows(a) {
                guard let p = axPoint(w, kAXPositionAttribute),
                      let s = axSize(w, kAXSizeAttribute), s.width > 1, s.height > 1 else { continue }
                idx += 1
                let title = axString(w, kAXTitleAttribute) ?? ""
                print("[\(idx)] \(a.localizedName ?? "?") — \"\(title)\""
                    + " pos=(\(Int(p.x)),\(Int(p.y))) size=\(Int(s.width))x\(Int(s.height))"
                    + " center=(\(Int(p.x + s.width/2)),\(Int(p.y + s.height/2))) pid=\(a.processIdentifier)")
            }
        }
        if idx == 0 { print("没有可见窗口"); return 1 }
        return 0

    case "focus", "move", "maximize", "fullscreen":
        guard args.count >= 4, let n = Int(args[3]) else { print("需要窗口序号"); return 2 }
        var idx = 0
        for a in apps {
            for w in axWindows(a) {
                guard let p = axPoint(w, kAXPositionAttribute),
                      let s = axSize(w, kAXSizeAttribute), s.width > 1, s.height > 1 else { continue }
                idx += 1
                if idx != n { continue }
                if gDry { print("dry: would \(args[2]) window [\(n)] \(a.localizedName ?? "?")"); return 0 }

                switch args[2] {
                case "focus":
                    let ok = activateApp(a, timeoutMS: 700)
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    let front = ok && waitFrontmost(a, timeoutMS: 250)
                    print("ok focused [\(n)] \(a.localizedName ?? "?")"
                        + (front ? "" : "（警告：未能确认成为前台 App — 下一击可能只用于激活窗口，必要时点两次）"))

                case "maximize":
                    // 先取消全屏态，否则尺寸设置会被忽略
                    var isFS: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &isFS) == .success,
                       let b = isFS as? Bool, b {
                        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
                        usleep(400_000)
                    }
                    let center = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
                    let target = displays().first { $0.contains(center) } ?? displays()[0]
                    let vf = target.visibleTL
                    // 顺序很重要：先定位到目标屏幕，再设尺寸。
                    // 反过来的话，尺寸会按窗口当前所在屏幕的可见区被裁剪。
                    var np = CGPoint(x: vf.origin.x, y: vf.origin.y)
                    if let v = AXValueCreate(.cgPoint, &np) {
                        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
                    }
                    usleep(150_000)
                    var ns = CGSize(width: vf.width, height: vf.height)
                    if let v = AXValueCreate(.cgSize, &ns) {
                        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
                    }
                    usleep(200_000)
                    // 再定位一次，纠正缩放后可能产生的偏移
                    if let v = AXValueCreate(.cgPoint, &np) {
                        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
                    }
                    usleep(150_000)
                    let np2 = axPoint(w, kAXPositionAttribute) ?? np
                    let ns2 = axSize(w, kAXSizeAttribute) ?? ns
                    var line = "ok maximized [\(n)] -> pos=(\(Int(np2.x)),\(Int(np2.y)))"
                        + " size=\(Int(ns2.width))x\(Int(ns2.height))"
                    if ns2.width < vf.width - 2 || ns2.height < vf.height - 2 {
                        line += "（小于可见区 \(Int(vf.width))x\(Int(vf.height))，该窗口可能自限尺寸）"
                    }
                    print(line)

                case "fullscreen":
                    var isFS: CFTypeRef?
                    AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &isFS)
                    let on = !((isFS as? Bool) ?? false)
                    let err = AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString,
                                                           on ? kCFBooleanTrue : kCFBooleanFalse)
                    print(err == .success
                          ? "ok fullscreen \(on ? "on" : "off") [\(n)]"
                          : "全屏切换失败（该窗口可能不支持，或需要「辅助功能」权限）")

                default: // move
                    guard args.count >= 6, let x = Double(args[4]), let y = Double(args[5]) else {
                        print("用法: win move N X Y [W H]"); return 2
                    }
                    var np = CGPoint(x: x, y: y)
                    if let v = AXValueCreate(.cgPoint, &np) {
                        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
                    }
                    if args.count >= 8, let ww = Double(args[6]), let hh = Double(args[7]) {
                        var ns = CGSize(width: ww, height: hh)
                        if let v = AXValueCreate(.cgSize, &ns) {
                            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
                        }
                    }
                    print("ok moved [\(n)] to (\(Int(x)),\(Int(y)))")
                }
                return 0
            }
        }
        print("没有序号为 \(n) 的窗口"); return 1

    default:
        print("未知子命令: \(args[2])"); return 2
    }
}

func doWaitFor(_ args: [String]) -> Int32 {
    var needle: String? = nil
    var stable = false
    var changePath: String? = nil
    var timeout = 20.0
    var interval = 0.6
    var fast = false
    var minChange = 2000         // --change 判定阈值：至少这么多像素变化才算「变了」
    var threshold = 12           // 单像素 RGB 差值阈值
    var display: Int? = nil, rect: CGRect? = nil
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--text":
            guard i + 1 < args.count else { return 2 }
            needle = args[i + 1]; i += 2
        case "--stable": stable = true; i += 1
        case "--change":
            guard i + 1 < args.count else { return 2 }
            changePath = (args[i + 1] as NSString).expandingTildeInPath; i += 2
        case "--timeout":
            guard i + 1 < args.count, let t = Double(args[i + 1]) else { return 2 }
            timeout = t; i += 2
        case "--interval":
            guard i + 1 < args.count, let t = Double(args[i + 1]) else { return 2 }
            interval = t; i += 2
        case "--fast": fast = true; i += 1
        case "--min-change":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { return 2 }
            minChange = n; i += 2
        case "--threshold":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { return 2 }
            threshold = n; i += 2
        case "-D":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { return 2 }
            display = n; i += 2
        case "-R":
            guard i + 1 < args.count, let r = parseRect(args[i + 1]) else { return 2 }
            rect = r; i += 2
        default: print("未知选项: \(args[i])"); return 2
        }
    }
    guard needle != nil || stable || changePath != nil else {
        print("需要 --text / --stable / --change 之一"); return 2
    }

    let t0 = Date()
    var lastHash: Int? = nil
    var lastBuf: (w: Int, h: Int, buf: [UInt8])? = nil
    var refBuf: (w: Int, h: Int, buf: [UInt8])? = nil
    if let cp = changePath {
        guard let b = rgbaBuffer(cp) else { print("无法读取参考图: \(cp)"); return 1 }
        refBuf = b
    }

    /// 与参考图比较，返回超过阈值的像素数
    func changedPixels(_ b: (w: Int, h: Int, buf: [UInt8]), _ ref: (w: Int, h: Int, buf: [UInt8])) -> Int? {
        guard b.w == ref.w, b.h == ref.h else { return nil }
        var cnt = 0
        var i = 0
        while i < b.buf.count {
            let d = abs(Int(b.buf[i]) - Int(ref.buf[i]))
                + abs(Int(b.buf[i + 1]) - Int(ref.buf[i + 1]))
                + abs(Int(b.buf[i + 2]) - Int(ref.buf[i + 2]))
            if d > threshold { cnt += 1 }
            i += 4
        }
        return cnt
    }

    while Date().timeIntervalSince(t0) < timeout {
        guard let c = capture(display: display, rect: rect) else { print("截图失败"); return 1 }
        let elapsed = Date().timeIntervalSince(t0)

        if let b = rgbaBuffer(c.path) {
            if let ref = refBuf {
                guard let cnt = changedPixels(b, ref) else {
                    print("参考图与当前截图尺寸不同，无法比较"); return 1
                }
                // 要求：相对参考图有明显变化，且画面已趋于稳定
                // （避免被旋转指示器/秒表这类持续动画误触发）
                if cnt >= minChange, let last = lastBuf,
                   let delta = changedPixels(b, last), delta <= max(20, cnt / 3) {
                    print("ok 画面已变化并稳定（\(String(format: "%.1f", elapsed))s，"
                        + "变化 \(cnt) 像素，帧间残留 \(delta)）")
                    return 0
                }
            }
            if stable {
                let h = b.buf.withUnsafeBytes { $0.reduce(into: 0) { $0 = $0 &* 31 &+ Int($1) } }
                if let last = lastHash, last == h {
                    print("ok 画面稳定（\(String(format: "%.1f", elapsed))s）"); return 0
                }
                lastHash = h
            }
            lastBuf = b
        }

        if let nd = needle, let hits = ocr(c.path, fast: fast) {
            if hits.contains(where: { $0.text.range(of: nd, options: .caseInsensitive) != nil }) {
                print("ok 找到「\(nd)」（\(String(format: "%.1f", elapsed))s）"); return 0
            }
        }
        Thread.sleep(forTimeInterval: interval)
    }
    print("超时 \(Int(timeout))s：条件未满足"); return 1
}

func doDiff(_ args: [String]) -> Int32 {
    guard args.count >= 4 else { print("用法: diff A.png B.png [--threshold 12] [-D N] [-R ...]"); return 2 }
    let aPath = (args[2] as NSString).expandingTildeInPath
    let bPath = (args[3] as NSString).expandingTildeInPath
    var threshold = 12
    var display: Int? = 1, rect: CGRect? = nil
    var i = 4
    while i < args.count {
        switch args[i] {
        case "--threshold":
            guard i + 1 < args.count, let t = Int(args[i + 1]) else { return 2 }
            threshold = t; i += 2
        case "-D":
            guard i + 1 < args.count, let n = Int(args[i + 1]) else { return 2 }
            display = n; i += 2
        case "-R":
            guard i + 1 < args.count, let r = parseRect(args[i + 1]) else { return 2 }
            rect = r; display = nil; i += 2
        default: print("未知选项: \(args[i])"); return 2
        }
    }
    guard let a = rgbaBuffer(aPath), let b = rgbaBuffer(bPath) else { print("无法读取图片"); return 1 }
    guard a.w == b.w, a.h == b.h else {
        print("尺寸不同: \(a.w)x\(a.h) vs \(b.w)x\(b.h)"); return 1
    }
    // 坐标映射：-R 给矩形，-D 给整屏
    var origin = CGPoint.zero
    var scale: CGFloat = 1
    var scaleKnown = true
    if let r = rect {
        origin = r.origin
        if let d = displays().first(where: { $0.contains(r.origin) }) {
            scale = d.scale
        } else {
            scaleKnown = false   // 矩形不在任何已知屏幕内，缩放只能按 1 猜
        }
    } else if let d = disp(index: display ?? 1) {
        origin = d.tlOrigin; scale = d.scale
    }
    if !scaleKnown {
        print("警告: -R 原点 (\(Int(origin.x)),\(Int(origin.y))) 不在任何屏幕内，scale 按 1 处理")
    }

    // -R 同时把比较范围限制在该区域内（换算成图内像素坐标并裁剪）
    var x0 = 0, y0 = 0, x1 = a.w, y1 = a.h
    if let r = rect {
        x0 = max(0, Int((r.minX - origin.x) * scale))
        y0 = max(0, Int((r.minY - origin.y) * scale))
        x1 = min(a.w, Int((r.maxX - origin.x) * scale))
        y1 = min(a.h, Int((r.maxY - origin.y) * scale))
        guard x1 > x0, y1 > y0 else {
            print("-R 区域不在图片范围内（图 \(a.w)x\(a.h)px，映射 origin=(\(Int(origin.x)),\(Int(origin.y))) scale=\(fmt(scale))）")
            return 2
        }
    }

    var minX = a.w, minY = a.h, maxX = -1, maxY = -1, changed = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let i2 = (y * a.w + x) * 4
            let d = abs(Int(a.buf[i2]) - Int(b.buf[i2]))
                + abs(Int(a.buf[i2 + 1]) - Int(b.buf[i2 + 1]))
                + abs(Int(a.buf[i2 + 2]) - Int(b.buf[i2 + 2]))
            if d > threshold {
                changed += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    let scope = rect == nil ? "全图" : "区域 \(Int(rect!.width))x\(Int(rect!.height))pt"
    guard changed > 0 else { print("ok 无差异（阈值 \(threshold)，\(scope)）"); return 0 }

    let pct = Double(changed) / Double((x1 - x0) * (y1 - y0)) * 100
    let gx1 = origin.x + CGFloat(minX) / scale, gy1 = origin.y + CGFloat(minY) / scale
    let gx2 = origin.x + CGFloat(maxX) / scale, gy2 = origin.y + CGFloat(maxY) / scale
    print("ok 变化 \(changed) 像素 (\(String(format: "%.2f", pct))% of \(scope))")
    print("   bbox_px=(\(minX),\(minY))-(\(maxX),\(maxY))"
        + " -> global=(\(Int(gx1)),\(Int(gy1)))-(\(Int(gx2)),\(Int(gy2)))"
        + " center=(\(Int((gx1 + gx2) / 2)),\(Int((gy1 + gy2) / 2)))")
    return 0
}

func doClipboard(_ args: [String]) -> Int32 {
    guard args.count >= 3 else { print("用法: clipboard get | set TEXT"); return 2 }
    switch args[2] {
    case "get":
        print(NSPasteboard.general.string(forType: .string) ?? "")
        return 0
    case "set":
        guard args.count >= 4 else { print("用法: clipboard set TEXT"); return 2 }
        let text = args[3...].joined(separator: " ")
        if gDry { print("dry: would set clipboard (\(text.count) 字符)"); return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("ok clipboard set (\(text.count) 字符)")
        return 0
    default:
        print("未知子命令: \(args[2])"); return 2
    }
}

func doBatch(_ args: [String]) -> Int32 {
    let keepGoing = args.contains("-c")
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { print("无法读取 stdin"); return 2 }
    var n = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        n += 1
        let parts = ["dsh-ui"] + splitArgs(line)
        print("> \(line)")
        let code = runCommand(parts)
        if code != 0 {
            print("批量在第 \(n) 条失败 (exit \(code))")
            if !keepGoing { return code }
        }
    }
    print("ok 批量完成 \(n) 条")
    return 0
}

// MARK: - 主分发

/// 解析一行 batch 脚本，支持单/双引号包裹的参数
func splitArgs(_ line: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var quote: Character? = nil
    var has = false
    for ch in line {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
            has = true
        } else if ch == "\"" || ch == "'" {
            quote = ch; has = true
        } else if ch == " " {
            if has { out.append(cur); cur = ""; has = false }
        } else {
            cur.append(ch); has = true
        }
    }
    if has { out.append(cur) }
    return out
}

/// 命令入口：剥离全局开关、执行、写审计（batch 的子命令也会各自留痕）
func runCommand(_ args: [String]) -> Int32 {
    var a = args
    if let idx = a.firstIndex(of: "--dry") {
        gDry = true
        a.remove(at: idx)
    }
    let code = dispatch(a)
    writeAudit(args, code)
    return code
}

func dispatch(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { print(helpText); return 2 }

    let cmd = args[1].lowercased()
    switch cmd {

    case "help", "-h", "--help":
        print(helpText); return 0

    case "displays":
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        print("main height = \(Int(mainH))pt  (左下->左上 换算基准)")
        for d in displays() {
            let v = d.visibleTL
            print("#\(d.index) pt=\(Int(d.ptSize.width))x\(Int(d.ptSize.height))"
                + " px=\(Int(d.pxSize.width))x\(Int(d.pxSize.height)) scale=\(fmt(d.scale))"
                + " origin_tl=(\(Int(d.tlOrigin.x)),\(Int(d.tlOrigin.y)))"
                + " frame_bl=(\(Int(d.blFrame.origin.x)),\(Int(d.blFrame.origin.y)))"
                + " visible_tl=(\(Int(v.origin.x)),\(Int(v.origin.y))) \(Int(v.width))x\(Int(v.height))")
        }
        return 0

    case "under":
        guard args.count >= 4 else { print("用法: under X Y"); return 2 }
        let p = point(args, 2)
        guard let u = appUnder(p) else { print("(\(Int(p.x)),\(Int(p.y))) 处没有 AX 元素"); return 1 }
        print("ok (\(Int(p.x)),\(Int(p.y))) -> \(u.name) [\(u.bundle)]")
        if denyList().contains(where: {
            $0.caseInsensitiveCompare(u.bundle) == .orderedSame
                || $0.caseInsensitiveCompare(u.name) == .orderedSame
        }) { print("   该 App 在拦截名单中，点击会被拒绝") }
        return 0

    case "guard":
        let dl = denyList()
        print("拦截名单: \(denyPath)")
        if dl.isEmpty { print("  (空 — 未启用任何拦截)") }
        else { for d in dl { print("  - \(d)") } }
        print("审计日志: \(auditPath)")
        if let s = try? String(contentsOfFile: auditPath, encoding: .utf8) {
            let lines = s.split(separator: "\n")
            print("  已有 \(lines.count) 条记录，最近 3 条:")
            for l in lines.suffix(3) { print("    \(l)") }
        } else {
            print("  (暂无记录)")
        }
        print("干跑模式: \(gDry ? "开" : "关")")
        return 0

    case "shot":    return doShot(args)
    case "find-text": return doFindText(args)
    case "find-ax": return doFindAx(args)
    case "win":     return doWin(args)
    case "wait-for": return doWaitFor(args)
    case "diff":    return doDiff(args)
    case "clipboard": return doClipboard(args)
    case "batch":   return doBatch(args)

    case "pos":
        printCursor(); return 0

    case "move":
        guard args.count >= 4 else { print("用法: move X Y"); return 2 }
        let p = point(args, 2)
        if gDry { print("dry: would move (\(Int(p.x)),\(Int(p.y)))"); return 0 }
        guard guardPoint(p) else { return 3 }
        post(.mouseMoved, p)
        printCursor(); return 0

    case "click", "dclick", "rclick", "tap", "press":
        guard args.count >= 4 else {
            print("用法: \(cmd) X Y" + ((cmd == "tap" || cmd == "press" || cmd == "click") ? " [MS]" : ""))
            return 2
        }
        let p = point(args, 2)
        // 可选按下时长（毫秒）：click 默认 30（与旧行为一致），tap 60，press 800（触发 iOS 长按菜单）
        let defaultHold = cmd == "press" ? 800 : (cmd == "tap" ? 60 : 30)
        var holdMS = defaultHold
        var autoActivate = true
        var ai = 4
        while ai < args.count {
            switch args[ai] {
            case "--no-activate": autoActivate = false; ai += 1
            default:
                if let v = Int(args[ai]) { holdMS = v; ai += 1 }
                else { print("未知选项: \(args[ai])"); return 2 }
            }
        }
        if gDry {
            print("dry: would \(cmd) (\(Int(p.x)),\(Int(p.y))) hold=\(holdMS)ms"
                + (autoActivate ? "" : " no-activate"))
            return 0
        }
        guard guardPoint(p) else { return 3 }
        if autoActivate, let note = ensureFrontmostForClick(p) {
            print("  \(note)")
            gNote = note          // 同时留痕到审计日志，便于事后解释焦点变化
        }
        switch cmd {
        case "click", "tap", "press":
            tapAt(p, holdMS: holdMS)
        case "dclick":
            tapAt(p, holdMS: 30); usleep(60_000); tapAt(p, holdMS: 30)
        default:
            post(.rightMouseDown, p, .right); usleep(30_000); post(.rightMouseUp, p, .right)
        }
        printCursor(); return 0

    case "drag":
        guard args.count >= 6 else {
            print("用法: drag X1 Y1 X2 Y2 [--ms N] [--steps N] [--hold N] [--settle N] [--momentum F] [--edge-guard N]")
            return 2
        }
        let s = point(args, 2), e = point(args, 4)
        // 默认值与旧实现完全一致：settle 80ms -> 按下 -> hold 80ms -> 12 步 / 共 216ms -> 抬起
        var moveMS = 216, steps = 12, holdMS = 80, settleMS = 80
        var momentum = 0.0
        var edgeGuard = 12.0
        var j = 6
        while j < args.count {
            switch args[j] {
            case "--ms":    guard j + 1 < args.count, let v = Int(args[j + 1]) else { return 2 }; moveMS = v; j += 2
            case "--steps": guard j + 1 < args.count, let v = Int(args[j + 1]) else { return 2 }; steps = v; j += 2
            case "--hold":  guard j + 1 < args.count, let v = Int(args[j + 1]) else { return 2 }; holdMS = v; j += 2
            case "--settle": guard j + 1 < args.count, let v = Int(args[j + 1]) else { return 2 }; settleMS = v; j += 2
            case "--momentum": guard j + 1 < args.count, let v = Double(args[j + 1]) else { return 2 }; momentum = v; j += 2
            case "--edge-guard": guard j + 1 < args.count, let v = Double(args[j + 1]) else { return 2 }; edgeGuard = v; j += 2
            default: print("未知选项: \(args[j])"); return 2
            }
        }
        // 先算护栏告警（只读 AX 查询），这样 --dry 也能报出来
        let dragWarn = edgeWarning(s, margin: CGFloat(edgeGuard))
        if gDry {
            print("dry: would drag (\(Int(s.x)),\(Int(s.y))) -> (\(Int(e.x)),\(Int(e.y)))"
                + " settle=\(settleMS) hold=\(holdMS) move=\(moveMS) steps=\(steps) momentum=\(momentum)")
            if let w = dragWarn { print("  警告: \(w)") }
            return 0
        }
        guard guardPoint(s) else { return 3 }
        if let w = dragWarn { print("  警告: \(w)") }
        dragGesture(from: s, to: e, settleMS: settleMS, holdMS: holdMS,
                    moveMS: moveMS, steps: steps, momentum: momentum)
        printCursor(); return 0

    case "scroll":
        guard args.count >= 3, let dy = Int32(args[2]) else { print("用法: scroll N [--drag]"); return 2 }
        var asDrag = false
        var j = 3
        while j < args.count {
            switch args[j] {
            case "--drag": asDrag = true; j += 1
            default: print("未知选项: \(args[j])"); return 2
            }
        }
        if gDry { print("dry: would scroll \(dy)\(asDrag ? " (as drag)" : "")"); return 0 }

        // --drag：部分界面（实测 iPhone 镜像）完全忽略合成滚轮事件，只能用拖拽模拟滚动。
        // 语义与滚轮一致：dy>0 = 向下滚 = 内容上移 = 手指上滑。
        if asDrag {
            let cur = currentGlobalCursor()
            let d = displays().first { $0.contains(cur) } ?? displays()[0]
            let vf = d.visibleTL
            let end = CGPoint(x: cur.x,
                              y: min(max(cur.y - CGFloat(dy), vf.minY + 6), vf.maxY - 6))
            guard guardPoint(cur) else { return 3 }
            if let w = edgeWarning(cur, margin: 12) { print("  警告: \(w)") }
            dragGesture(from: cur, to: end, settleMS: 60, holdMS: 90, moveMS: 260,
                        steps: 18, momentum: 1.0)
            print("ok 以拖拽模拟滚动 \(dy)px: (\(Int(cur.x)),\(Int(cur.y))) -> (\(Int(end.x)),\(Int(end.y)))")
            return 0
        }
        // 必须模拟一次完整的滚动手势：单个大幅度事件会被不少界面忽略。
        // 实测钉钉导航面板只认「phase 序列 + 小步长增量」，而单个 600px 事件毫无反应。
        let src = CGEventSource(stateID: .hidSystemState)
        func mk(_ d: Int32, _ phase: Int64, _ mom: Int64) -> CGEvent {
            let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                            wheel1: d, wheel2: 0, wheel3: 0)!
            if let c = CGEvent(source: nil)?.location { e.location = c }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mom)
            return e
        }
        let perEvent: Int32 = 20                       // 单步最多 20px，贴近真实触控板
        let steps = max(1, min(150, abs(dy) / perEvent))
        let stepDelta = dy / Int32(steps)
        let remainder = dy - stepDelta * Int32(steps)
        mk(0, 1, 0).post(tap: .cghidEventTap)          // phase: began
        usleep(16_000)
        for i in 0..<Int(steps) {
            let d = stepDelta + (i == Int(steps) - 1 ? remainder : 0)
            mk(d, 2, 0).post(tap: .cghidEventTap)      // phase: changed
            usleep(14_000)
        }
        mk(0, 4, 0).post(tap: .cghidEventTap)          // phase: ended
        usleep(30_000)
        mk(0, 0, 1).post(tap: .cghidEventTap)          // momentum began
        usleep(16_000)
        for _ in 0..<12 {
            mk(stepDelta / 2, 0, 2).post(tap: .cghidEventTap)
            usleep(16_000)
        }
        mk(0, 0, 4).post(tap: .cghidEventTap)          // momentum ended
        return 0

    case "type":
        guard args.count >= 3 else { print("用法: type TEXT"); return 2 }
        let text = args[2...].joined(separator: " ")
        if gDry { print("dry: would type \(text.count) 字符"); return 0 }
        typeString(text)
        return 0

    case "keys":
        guard args.count >= 3 else { print("用法: keys TEXT"); return 2 }
        let ktext = args[2...].joined(separator: " ")
        if gDry {
            // 干跑时逐字符列出「字符 -> 键码(+shift)」，用于核对映射而不真的敲键盘
            var parts: [String] = []
            for ch in ktext {
                if let st = strokeFor(ch) {
                    parts.append("\(ch)=\(st.code)\(st.shift ? "+shift" : "")")
                } else {
                    parts.append("\(ch)=无键码")
                }
            }
            print("dry: would send \(ktext.count) 个键码字符:")
            print("  " + parts.joined(separator: " "))
            return 0
        }
        let kr = typeKeys(ktext)
        var kline = "ok keys 发送 \(kr.sent) 个字符"
        if !kr.skipped.isEmpty {
            kline += "；跳过 \(kr.skipped.count) 个无键码字符: \(String(kr.skipped))"
        }
        print(kline)
        return kr.sent > 0 ? 0 : 1

    case "key":
        guard args.count >= 3 else { print("用法: key KEY"); return 2 }
        var spec = args[2]
        var flags: CGEventFlags = []
        if spec.contains("+") {
            let parts = spec.split(separator: "+").map(String.init)
            spec = parts.last!
            for m in parts.dropLast() {
                guard let f = modifierMap[m.lowercased()] else { print("未知修饰键: \(m)"); return 2 }
                flags.insert(f)
            }
        }
        guard let code = keyMap[spec.lowercased()] else { print("未知按键: \(spec)"); return 2 }
        if gDry { print("dry: would press \(args[2])"); return 0 }
        keyEvent(code, true, flags); usleep(20_000); keyEvent(code, false, flags)
        return 0

    default:
        print("未知命令: \(args[1])\n")
        print(helpText)
        return 2
    }
}

// MARK: - 入口

try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
exit(runCommand(CommandLine.arguments))
