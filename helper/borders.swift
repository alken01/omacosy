// omacosy-borders — focused-window ring, replacing JankyBorders.
// One click-through overlay window whose CAShapeLayer stroke is
// rasterized by the WindowServer (no window-sized client bitmaps — the
// architecture that made JankyBorders cost hundreds of MB). Needs no
// permissions at all.
//
// Hybrid event/poll design: everything that HAS an event is
// event-driven (kqueue watches on the workspace-switch signal, theme
// and config; NSWorkspace app-activation notifications); the 120ms
// poll remains solely as frame truth, because window move/resize has
// no public event without an Accessibility grant.
import AppKit

let pollSeconds = 0.12

// styling from ~/.config/omacosy/borders.conf (width, radius, per-app
// radius overrides)
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
            wd > 60, h > 60
        else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        // AeroSpace drags windows through offscreen stash positions
        // during workspace switches — ringing those mid-flight frames
        // is flicker. Only mostly-onscreen windows qualify.
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        var visible: CGFloat = 0
        if CGGetActiveDisplayList(8, &ids, &n) == .success {
            for i in 0..<Int(n) {
                let inter = rect.intersection(CGDisplayBounds(ids[i]))
                if !inter.isNull { visible += inter.width * inter.height }
            }
        }
        if visible / (rect.width * rect.height) < 0.7 { continue }
        return (rect, name)
    }
    return nil
}

// CG top-left global coords -> Cocoa bottom-left global coords
func cocoaRect(_ r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
        width: r.width, height: r.height)
}

// notch height (safe-area top) of the NSScreen matching a CG display —
// fullscreen windows on notched displays start below the camera strip
func safeTop(for d: CGRect) -> CGFloat {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    for scr in NSScreen.screens {
        let cgY = primaryH - scr.frame.maxY
        if abs(scr.frame.origin.x - d.origin.x) < 2, abs(cgY - d.origin.y) < 2 {
            return scr.safeAreaInsets.top
        }
    }
    return 0
}

func isFullscreen(_ r: CGRect) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return false }
    for i in 0..<Int(n) {
        let d = CGDisplayBounds(ids[i])
        guard d.intersects(r) else { continue }
        // native fullscreen (incl. split-view halves): starts at the
        // display top or just below the notch strip, and spans the
        // remaining height. Managed windows never do — the bar owns
        // that edge.
        let inset = safeTop(for: d)
        if r.origin.y - d.origin.y < inset + 3, r.height >= d.height - inset - 6 {
            return true
        }
    }
    return false
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

let logURL = URL(fileURLWithPath: "/tmp/omacosy-borders.log")
let logFmt = ISO8601DateFormatter()
func tlog(_ m: String) {
    let line = "\(logFmt.string(from: Date())) \(m)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

// --- window ------------------------------------------------------------

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

// --- state + tick ------------------------------------------------------

var conf = loadConf()
var missTicks = 0
var pendingFrame = CGRect.zero
var pendingApp = ""
var pendingTicks = 0
var justHid = true
var lastFrame = CGRect.zero
shape.strokeColor = loadColor()
shape.lineWidth = conf.width

func hideRing(_ reason: String) {
    if win.isVisible {
        win.orderOut(nil)
        tlog("hide reason=\(reason)")
    }
    lastFrame = .zero
    justHid = true
    pendingTicks = 0
}

func tick() {
    guard let hit = focusedWindowFrame(), case let (f, appName) = hit, !isFullscreen(f) else {
        // transient misses happen around app switches and popups —
        // only hide after a few consecutive ones, or the ring blinks
        missTicks += 1
        if missTicks >= 3 { hideRing("miss-or-fullscreen") }
        return
    }
    missTicks = 0

    // stability gate: mid-flight windows move every tick; only a frame
    // seen identically across polls may be ringed. The old ring hides
    // the moment the target changes — never display stale geometry.
    if f != pendingFrame || appName != pendingApp {
        pendingFrame = f
        pendingApp = appName
        pendingTicks = 1
        if win.isVisible, f != lastFrame { hideRing("target-changed") }
        return
    }
    pendingTicks += 1
    // transitions come in bursts right after a hide: mid-flight frames
    // can pause a beat, so the first show after hiding needs twice the
    // stillness before the ring commits
    if pendingTicks < (justHid ? 4 : 2) { return }
    justHid = false

    guard f != lastFrame || !win.isVisible else { return }
    // crossing displays: hide for the jump so the ring never visibly
    // travels between screens
    if win.isVisible, displayOf(f) != displayOf(lastFrame) {
        win.orderOut(nil)
        tlog("jump-display app=\(appName)")
    }
    lastFrame = f

    let radius = conf.appRadius[appName] ?? conf.radius
    let pad = conf.width // ring sits just outside the window edge
    let outer = cocoaRect(f.insetBy(dx: -pad, dy: -pad))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    win.setFrame(outer, display: false)
    let bounds = CGRect(origin: .zero, size: outer.size)
    shape.frame = bounds
    let inset = bounds.insetBy(dx: conf.width / 2, dy: conf.width / 2)
    shape.path = CGPath(roundedRect: inset, cornerWidth: radius,
        cornerHeight: radius, transform: nil)
    CATransaction.commit()
    if !win.isVisible {
        win.orderFrontRegardless()
        tlog("show app=\(appName) f=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
    }
}

// --- event sources -----------------------------------------------------

var sources: [any DispatchSourceFileSystemObject] = []

// kqueue watch with auto re-arm: editors and cp replace files (rename),
// so a dead vnode watch must recreate itself against the new file
func watch(_ path: String, create: Bool, handler: @escaping () -> Void) {
    if create, !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        // target missing (e.g. theme not applied yet): retry later
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            watch(path, create: create, handler: handler)
        }
        return
    }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
        eventMask: [.write, .attrib, .delete, .rename], queue: .main)
    src.setEventHandler {
        let ev = src.data
        handler()
        if ev.contains(.delete) || ev.contains(.rename) { src.cancel() }
    }
    src.setCancelHandler {
        close(fd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            watch(path, create: create, handler: handler)
        }
    }
    sources.append(src)
    src.resume()
}

// aerospace announces workspace switches by touching this file
// (exec-on-workspace-change): hide instantly, don't wait for stale
// frontmost/frame data to catch up
watch("/tmp/omacosy-ws-switch", create: true) { hideRing("workspace-switch") }

// theme-set swaps the ~/.config/omarchy/current/theme symlink — watch
// the directory; the file behind the old symlink never changes itself
watch(FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omarchy/current").path, create: false) {
    shape.strokeColor = loadColor()
}

watch(confFile.path, create: false) {
    conf = loadConf()
    shape.lineWidth = conf.width
    lastFrame = .zero // force redraw with new geometry
}

// app activation: react now instead of on the next poll
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { _ in tick() }

let timer = Timer(timeInterval: pollSeconds, repeats: true) { _ in tick() }
RunLoop.current.add(timer, forMode: .common)
app.run()
