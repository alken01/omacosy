// omacosy-borders — focused-window ring, replacing JankyBorders.
// One click-through overlay window whose CAShapeLayer stroke is
// rasterized by the WindowServer (no window-sized client bitmaps — the
// architecture that made JankyBorders cost hundreds of MB). Polls the
// frontmost window like omacosy-ffm; needs no permissions at all.
//
// Color comes from the active theme's borders.sh (ACTIVE_COLOR=0xAARRGGBB),
// re-read whenever the file's mtime changes, so theme-set keeps working
// without talking to this daemon.
import AppKit

let pollSeconds = 0.08

// styling from ~/.config/omacosy/borders.conf (width, radius, per-app
// radius overrides), re-read when the file changes
struct Conf {
    var width: CGFloat = 4
    var radius: CGFloat = 10
    var appRadius: [String: CGFloat] = [:]
}
let confFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omacosy/borders.conf")

func loadConf() -> Conf {
    var c = Conf()
    guard let text = try? String(contentsOf: confFile, encoding: .utf8) else { return c }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if key == "width", let v = Double(val) { c.width = CGFloat(v) }
        else if key == "radius", let v = Double(val) { c.radius = CGFloat(v) }
        else if key.hasPrefix("radius:"), let v = Double(val) {
            c.appRadius[String(key.dropFirst(7)).lowercased()] = CGFloat(v)
        }
    }
    return c
}

func confMtime() -> Date {
    (try? FileManager.default.attributesOfItem(atPath: confFile.path)[.modificationDate] as? Date)
        .flatMap { $0 } ?? .distantPast
}

let themeFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omarchy/current/theme/borders.sh")

func loadColor() -> CGColor {
    guard let text = try? String(contentsOf: themeFile, encoding: .utf8) else {
        return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    }
    for line in text.split(separator: "\n") {
        guard let range = line.range(of: "ACTIVE_COLOR=0x") else { continue }
        let hex = String(line[range.upperBound...]).prefix(8)
        guard hex.count == 8, let v = UInt32(hex, radix: 16) else { continue }
        return CGColor(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: CGFloat((v >> 24) & 0xff) / 255)
    }
    return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
}

func themeMtime() -> Date {
    (try? FileManager.default.attributesOfItem(atPath: themeFile.path)[.modificationDate] as? Date)
        .flatMap { $0 } ?? .distantPast
}

// frontmost app's topmost normal window, in CG (top-left) coordinates
func focusedWindowFrame() -> (CGRect, String)? {
    guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = front.processIdentifier
    let name = (front.localizedName ?? "").lowercased()
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list { // front-to-back
        guard (w["kCGWindowLayer"] as? Int) == 0,
            (w["kCGWindowOwnerPID"] as? pid_t) == pid,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            wd > 40, h > 40
        else { continue }
        return (CGRect(x: x, y: y, width: wd, height: h), name)
    }
    return nil
}

// CG top-left global coords -> Cocoa bottom-left global coords
func cocoaRect(_ r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
        width: r.width, height: r.height)
}

func displayOf(_ r: CGRect) -> CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return 0 }
    let c = CGPoint(x: r.midX, y: r.midY)
    for i in 0..<Int(n) where CGDisplayBounds(ids[i]).contains(c) {
        return ids[i]
    }
    return 0
}

func isFullscreen(_ r: CGRect) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return false }
    for i in 0..<Int(n) {
        let d = CGDisplayBounds(ids[i])
        if abs(d.origin.x - r.origin.x) < 2, abs(d.origin.y - r.origin.y) < 2,
            abs(d.width - r.width) < 2, abs(d.height - r.height) < 2 {
            return true
        }
    }
    return false
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
    styleMask: .borderless, backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.ignoresMouseEvents = true
win.hasShadow = false
win.level = .floating
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

let view = NSView(frame: .zero)
view.wantsLayer = true
let shape = CAShapeLayer()
shape.fillColor = nil
view.layer?.addSublayer(shape)
win.contentView = view

var conf = loadConf()
var missTicks = 0
var lastFrame = CGRect.zero
var lastMtime = Date.distantPast
var lastConfMtime = confMtime()
shape.strokeColor = loadColor()
shape.lineWidth = conf.width

let timer = Timer(timeInterval: pollSeconds, repeats: true) { _ in
    let mtime = themeMtime()
    if mtime != lastMtime {
        lastMtime = mtime
        shape.strokeColor = loadColor()
    }
    let cm = confMtime()
    if cm != lastConfMtime {
        lastConfMtime = cm
        conf = loadConf()
        shape.lineWidth = conf.width
        lastFrame = .zero // force redraw with new geometry
    }

    guard let hit = focusedWindowFrame(), case let (f, appName) = hit, !isFullscreen(f) else {
        // transient misses happen around app switches and popups —
        // only hide after a few consecutive ones, or the ring blinks
        missTicks += 1
        if missTicks >= 3, win.isVisible {
            win.orderOut(nil)
            lastFrame = .zero
        }
        return
    }
    missTicks = 0
    guard f != lastFrame || !win.isVisible else { return }
    // crossing displays: hide for the jump so the ring never visibly
    // travels between screens
    if win.isVisible, displayOf(f) != displayOf(lastFrame) {
        win.orderOut(nil)
    }
    lastFrame = f

    let radius = conf.appRadius[appName] ?? conf.radius
    let pad = conf.width // ring sits just outside the window edge
    let outer = cocoaRect(f.insetBy(dx: -pad, dy: -pad))
    // suppress implicit animations so the ring snaps with the window
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    win.setFrame(outer, display: false)
    let bounds = CGRect(origin: .zero, size: outer.size)
    shape.frame = bounds
    let inset = bounds.insetBy(dx: conf.width / 2, dy: conf.width / 2)
    shape.path = CGPath(roundedRect: inset, cornerWidth: radius,
        cornerHeight: radius, transform: nil)
    CATransaction.commit()
    if !win.isVisible { win.orderFrontRegardless() }
}
RunLoop.current.add(timer, forMode: .common)
app.run()
