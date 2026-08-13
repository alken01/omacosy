// omacosy-overview — the workspace overview Mission Control can't be.
// AeroSpace workspaces aren't Spaces, so MC shows one undifferentiated
// window pile; this overlay asks AeroSpace itself and draws a card per
// non-empty workspace with LIVE window previews (ScreenCaptureKit —
// captures work even for AeroSpace's offscreen-stashed windows),
// composed into an approximated tile layout. Click a card or press its
// digit to switch; Esc, backdrop click, losing key, or swiping up
// again hides it.
//
// Resident daemon for latency: the first invocation self-daemonizes
// (or launchd starts it with --daemon), every later invocation just
// signals SIGUSR1 to toggle — the window and thumbnail cache are
// already warm, so the overlay appears instantly. Thumbnails render
// from cache at once and refresh in place as new captures land.
//
// Screen Recording permission: first capture prompts once; until
// granted the cards fall back to icons + titles.
import AppKit
import ScreenCaptureKit

// Private SkyLight focus — same primitive omacosy-ffm uses. Keyboard
// events only reach the ACTIVE app's key window, and cooperative
// activation silently refuses a background daemon poked from the
// swipe helper — so the overlay focuses ITSELF the way the window
// managers do, and hands focus back on plain dismissal.
struct PSN { var hi: UInt32 = 0, lo: UInt32 = 0 }
@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout PSN) -> OSStatus
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func SLPSSetFrontProcess(_ psn: inout PSN, _ wid: UInt32, _ mode: UInt32) -> Int32
@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEvent(_ psn: inout PSN, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32

func slpsFocus(pid: pid_t, wid: UInt32) {
    var psn = PSN()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    _ = SLPSSetFrontProcess(&psn, wid, 0x200)
    var w = wid
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: &w) { src in
        for i in 0..<4 { bytes[0x3c + i] = src[i] }
    }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
    bytes[0x08] = 0x02
    bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
}

var previousFront: (pid: pid_t, wid: UInt32)? = nil

func rememberFront() {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { previousFront = nil; return }
    for w in list where (w["kCGWindowLayer"] as? Int) == 0
        && (w["kCGWindowOwnerPID"] as? pid_t) == pid {
        if let n = w["kCGWindowNumber"] as? Int {
            previousFront = (pid, UInt32(n))
            return
        }
    }
    previousFront = nil
}

let pidPath = "/tmp/omacosy-overview-\(getuid()).pid"
// raised while the overlay is on screen — omacosy-ffm stands down so
// hover-focus can't steal key from under the user's click
let activeFlag = "/tmp/omacosy-overlay-active-\(getuid())"
let isDaemon = CommandLine.arguments.contains("--daemon")
let showOnLaunch = CommandLine.arguments.contains("--show")

// --- CLI entry: signal the daemon, or become it --------------------------

if !isDaemon {
    if let old = try? String(contentsOfFile: pidPath, encoding: .utf8),
        let pid = pid_t(old.trimmingCharacters(in: .whitespacesAndNewlines)),
        kill(pid, 0) == 0 {
        kill(pid, SIGUSR1) // toggle
        exit(0)
    }
    // no daemon yet: spawn one detached that shows immediately
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--daemon", "--show"]
    try? p.run()
    exit(0)
}

try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)
signal(SIGTERM) { _ in
    try? FileManager.default.removeItem(atPath: pidPath)
    exit(0)
}
signal(SIGUSR1, SIG_IGN) // delivered via DispatchSource below

let logURL = URL(fileURLWithPath: "/tmp/omacosy-overview.log")
func tlog(_ m: String) {
    let line = "\(Date()) \(m)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

// --- aerospace ----------------------------------------------------------

let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"

func aerospace(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: aerospaceBin)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

struct Win {
    let id: UInt32
    let app: String
    let title: String
    let bundle: String
}

func snapshotWorkspaces() -> (order: [String], wins: [String: [Win]], focused: String) {
    // one CLI round-trip: windows carry their workspace's focused flag
    var wins: [String: [Win]] = [:]
    var focused = ""
    for line in aerospace(["list-windows", "--all", "--format",
        "%{workspace}\t%{window-id}\t%{app-name}\t%{window-title}\t%{app-bundle-path}\t%{workspace-is-focused}"])
        .split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6, !f[0].isEmpty, let wid = UInt32(f[1]) else { continue }
        wins[f[0], default: []].append(Win(id: wid, app: f[2], title: f[3], bundle: f[4]))
        if f[5] == "true" { focused = f[0] }
    }
    if focused.isEmpty { // focused workspace holds no windows
        focused = aerospace(["list-workspaces", "--focused"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var order = Array(wins.keys)
    if !focused.isEmpty, !order.contains(focused) { order.append(focused) }
    order.sort { a, b in
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a < b
        }
    }
    return (order, wins, focused)
}

// --- theme ---------------------------------------------------------------

func themeAccent() -> NSColor {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omarchy/current/theme/borders.sh")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else {
        return NSColor(calibratedRed: 0.31, green: 0.58, blue: 0.46, alpha: 1)
    }
    for line in text.split(separator: "\n") {
        guard let r = line.range(of: "ACTIVE_COLOR=0x") else { continue }
        let hex = String(line[r.upperBound...]).prefix(8)
        guard hex.count == 8, let v = UInt32(hex, radix: 16) else { continue }
        return NSColor(
            calibratedRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1)
    }
    return NSColor(calibratedRed: 0.31, green: 0.58, blue: 0.46, alpha: 1)
}

// --- thumbnails (ScreenCaptureKit) ---------------------------------------

func croppedToContent(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    guard w > 0, h > 0,
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }
    var minX = w, maxX = -1, minY = h, maxY = -1
    let step = max(1, min(w, h) / 256)
    for y in stride(from: 0, to: h, by: step) {
        for x in stride(from: 0, to: w, by: step) {
            if data[(y * w + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX > minX + 40, maxY > minY + 40,
        maxX - minX < w - step || maxY - minY < h - step,
        let cropped = img.cropping(to: CGRect(x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1)) else { return img }
    return cropped
}

var thumbs: [UInt32: CGImage] = [:]
var thumbViews: [UInt32: NSView] = [:]

func refreshThumbs(_ ids: [UInt32]) {
    Task {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        for scw in content.windows {
            let wid = UInt32(scw.windowID)
            guard ids.contains(wid), scw.frame.width > 40, scw.frame.height > 40 else { continue }
            let cfg = SCStreamConfiguration()
            // half resolution is plenty for a card slot and halves the work
            cfg.width = Int(scw.frame.width)
            cfg.height = Int(scw.frame.height)
            cfg.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: scw)
            guard var img = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg) else { continue }
            // captures racing AeroSpace's stash/settle move come back
            // with the content in a corner of a padded canvas — crop
            // to the opaque bounding box so slots always fill
            img = croppedToContent(img)
            await MainActor.run {
                thumbs[wid] = img
                if let v = thumbViews[wid] {
                    v.layer?.contents = img
                    v.layer?.contentsGravity = .resizeAspectFill
                }
            }
        }
    }
}

// --- UI ------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let accent = themeAccent()

// A NON-ACTIVATING panel (the Spotlight/Raycast recipe): it becomes
// key — keyboard + clicks work instantly — WITHOUT activating our
// app. Crucial because cooperative activation silently refuses a
// background daemon poked from the swipe helper: a plain NSWindow
// showed but never became key, so clicks were swallowed by the
// activation attempt and digits went to the previously active app.
final class KeyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

var shownIds: [String] = []
var overlayVisible = false

let win = KeyWindow(contentRect: NSScreen.main!.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered, defer: false)
win.becomesKeyOnlyIfNeeded = false
win.isFloatingPanel = true
win.level = .popUpMenu
win.isOpaque = false
win.backgroundColor = NSColor.black.withAlphaComponent(0.72)
win.hasShadow = false
win.animationBehavior = .none
win.collectionBehavior = [.canJoinAllSpaces, .stationary]

func revealIfReady(_ content: ContentView) {
    guard content.shotReady, content.cardsReady else { return }
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.22
        content.cards.animator().alphaValue = 1
    }
}

func applyBackdrop(_ content: ContentView, shot: CGImage?) {
    guard !content.shotReady else { return }
    content.shotReady = true
    if let shot = shot {
        content.shotLayer.contents = shot
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.24)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        content.shotLayer.setAffineTransform(CGAffineTransform(scaleX: 0.93, y: 0.93))
        content.dimLayer.opacity = 0.72
        CATransaction.commit()
    } else {
        // no screenshot (permission missing / capture failed): plain dim
        content.dimLayer.opacity = 0.72
    }
    revealIfReady(content)
}

func captureBackdrop(screen: NSScreen, into content: ContentView) {
    let did = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value ?? 0
    Task {
        var shot: CGImage? = nil
        if let sc = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let disp = sc.displays.first(where: { $0.displayID == did }) ?? sc.displays.first {
            let cfg = SCStreamConfiguration()
            cfg.width = disp.width
            cfg.height = disp.height
            cfg.showsCursor = false
            let filter = SCContentFilter(display: disp, excludingWindows: [])
            shot = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
        let s = shot
        await MainActor.run {
            guard overlayVisible, win.contentView === content else { return }
            applyBackdrop(content, shot: s)
        }
    }
    // capture running late must not hold the whole overlay hostage
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak content] in
        if let c = content, overlayVisible, win.contentView === c {
            applyBackdrop(c, shot: nil)
        }
    }
}

func hideOverlay() {
    tlog("hideOverlay visible=\(overlayVisible) winVisible=\(win.isVisible)")
    guard overlayVisible else { return }
    overlayVisible = false
    try? FileManager.default.removeItem(atPath: activeFlag)
    win.orderOut(nil)
    tlog("  after orderOut winVisible=\(win.isVisible)")
    if let prev = previousFront {
        previousFront = nil
        slpsFocus(pid: prev.pid, wid: prev.wid)
    }
}

func switchTo(_ ws: String) {
    tlog("switchTo \(ws)")
    previousFront = nil // aerospace assigns focus; nothing to restore
    hideOverlay()
    DispatchQueue.global().async {
        let out = aerospace(["workspace", ws])
        tlog("aerospace workspace \(ws) -> '\(out.trimmingCharacters(in: .whitespacesAndNewlines))'")
    }
}

final class ContentView: NSView {
    var cardRects: [(NSRect, String)] = []
    // MC-style backdrop: screenshot of the desktop zooming back under
    // a dim wash while the cards fade in
    let shotLayer = CALayer()
    let dimLayer = CALayer()
    let cards = NSView()
    var shotReady = false
    var cardsReady = false
    override var acceptsFirstResponder: Bool { true }
    // every click belongs to the overlay itself — labels and image
    // views inside cards must never swallow a mouseDown
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        tlog("mouseDown at \(Int(p.x)),\(Int(p.y)) cards=\(cardRects.count)")
        for (r, ws) in cardRects where r.contains(p) {
            tlog("  hit card \(ws)")
            switchTo(ws)
            return
        }
        tlog("  backdrop -> hide")
        hideOverlay()
    }
    override func keyDown(with event: NSEvent) {
        tlog("keyDown code=\(event.keyCode) chars='\(event.charactersIgnoringModifiers ?? "")' shown=\(shownIds)")
        if event.keyCode == 53 { hideOverlay(); return } // esc
        if let ch = event.charactersIgnoringModifiers, shownIds.contains(ch) {
            switchTo(ch)
        }
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

// approximated tile layout for a preview canvas: AeroSpace only knows
// real frames for the visible workspace (hidden ones sit at stash
// positions), so slots mimic the default h_tiles split
func slotRects(_ n: Int, in r: NSRect) -> [NSRect] {
    let g: CGFloat = 4
    switch n {
    case 1: return [r]
    case 2:
        let w = (r.width - g) / 2
        return [
            NSRect(x: r.minX, y: r.minY, width: w, height: r.height),
            NSRect(x: r.minX + w + g, y: r.minY, width: w, height: r.height),
        ]
    case 3:
        let w = (r.width - g) / 2
        let h = (r.height - g) / 2
        return [
            NSRect(x: r.minX, y: r.minY, width: w, height: r.height),
            NSRect(x: r.minX + w + g, y: r.minY + h + g, width: w, height: h),
            NSRect(x: r.minX + w + g, y: r.minY, width: w, height: h),
        ]
    default:
        let w = (r.width - g) / 2
        let h = (r.height - g) / 2
        return [
            NSRect(x: r.minX, y: r.minY + h + g, width: w, height: h),
            NSRect(x: r.minX + w + g, y: r.minY + h + g, width: w, height: h),
            NSRect(x: r.minX, y: r.minY, width: w, height: h),
            NSRect(x: r.minX + w + g, y: r.minY, width: w, height: h),
        ]
    }
}

let cardW: CGFloat = 320
let previewH: CGFloat = 180
let headH: CGFloat = 40
let cardH = headH + previewH + 12
let gap: CGFloat = 24

func buildOverlay(_ snap: (order: [String], wins: [String: [Win]], focused: String), into content: ContentView) {
    let (order, wins, focused) = snap
    let shown = order.filter { wins[$0] != nil || $0 == focused }
    guard !shown.isEmpty else { return }
    shownIds = shown
    thumbViews.removeAll()
    let screen = win.screen ?? NSScreen.main!

    let cols = min(shown.count, shown.count <= 4 ? shown.count : 3)
    let rows = stride(from: 0, to: shown.count, by: cols).map {
        Array(shown[$0..<min($0 + cols, shown.count)])
    }
    let gridH = CGFloat(rows.count) * cardH + CGFloat(rows.count - 1) * gap
    var y = (screen.frame.height + gridH) / 2

    for row in rows {
        let rowW = CGFloat(row.count) * cardW + CGFloat(row.count - 1) * gap
        var x = (screen.frame.width - rowW) / 2
        for ws in row {
            let items = wins[ws] ?? []
            let rect = NSRect(x: x, y: y - cardH, width: cardW, height: cardH)
            let card = NSView(frame: rect)
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
            card.layer?.cornerRadius = 12
            if ws == focused {
                card.layer?.borderColor = accent.cgColor
                card.layer?.borderWidth = 2
            }
            let num = label(ws, size: 20, weight: .bold,
                color: ws == focused ? accent : NSColor(calibratedWhite: 0.85, alpha: 1))
            num.frame = NSRect(x: 14, y: cardH - 32, width: 40, height: 24)
            card.addSubview(num)
            // app icons beside the number, right-aligned
            for (i, w) in items.prefix(6).enumerated() {
                let iv = NSImageView(frame: NSRect(
                    x: cardW - 14 - CGFloat(i + 1) * 24, y: cardH - 31, width: 20, height: 20))
                iv.image = NSWorkspace.shared.icon(forFile: w.bundle)
                card.addSubview(iv)
            }
            // preview canvas: composed slot thumbnails
            let canvas = NSRect(x: 12, y: 10, width: cardW - 24, height: previewH)
            let visible = Array(items.prefix(4))
            for (w, slot) in zip(visible, slotRects(visible.count, in: canvas)) {
                // layer contents with aspect-FILL, Mission-Control
                // style — NSImageView only aspect-fits, which
                // letterboxed the capture inside the slot
                let sv = NSView(frame: slot)
                sv.wantsLayer = true
                sv.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
                sv.layer?.cornerRadius = 6
                sv.layer?.masksToBounds = true
                if let t = thumbs[w.id] {
                    sv.layer?.contents = t
                    sv.layer?.contentsGravity = .resizeAspectFill
                } else {
                    var rect = NSRect(origin: .zero, size: NSSize(width: 32, height: 32))
                    sv.layer?.contents = NSWorkspace.shared.icon(forFile: w.bundle)
                        .cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    sv.layer?.contentsGravity = .center
                }
                thumbViews[w.id] = sv
                card.addSubview(sv)
            }
            if items.count > 4 {
                let more = label("+\(items.count - 4)", size: 12, weight: .semibold,
                    color: NSColor(calibratedWhite: 0.6, alpha: 1))
                more.frame = NSRect(x: canvas.maxX - 34, y: canvas.minY + 6, width: 30, height: 16)
                card.addSubview(more)
            }
            content.cards.addSubview(card)
            content.cardRects.append((rect, ws))
            x += cardW + gap
        }
        y -= cardH + gap
    }

    let hint = label("click / 1-9 to switch · esc or swipe up to close",
        size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.5, alpha: 1))
    hint.alignment = .center
    hint.frame = NSRect(x: 0, y: max((screen.frame.height - gridH) / 2 - 44, 12),
        width: screen.frame.width, height: 18)
    content.cards.addSubview(hint)

    win.makeFirstResponder(content)
    content.cardsReady = true
    revealIfReady(content)
    refreshThumbs(shown.flatMap { (wins[$0] ?? []).prefix(4).map(\.id) })
}

func showOverlay() {
    guard !overlayVisible else { return }
    overlayVisible = true
    // the backdrop orders front IMMEDIATELY — everything data-driven
    // (aerospace query, icons, thumbnails) fills in asynchronously, so
    // the swipe response is the window server's latency, nothing else
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
    win.setFrame(screen.frame, display: false)
    let placeholder = ContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
    placeholder.wantsLayer = true
    // transparent window + layered backdrop: the first frames look
    // exactly like the desktop, then the screenshot zooms back
    win.backgroundColor = .clear
    placeholder.layer?.backgroundColor = NSColor.clear.cgColor
    placeholder.shotLayer.frame = placeholder.bounds
    placeholder.shotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    placeholder.shotLayer.position = CGPoint(x: placeholder.bounds.midX, y: placeholder.bounds.midY)
    placeholder.layer?.addSublayer(placeholder.shotLayer)
    placeholder.dimLayer.frame = placeholder.bounds
    placeholder.dimLayer.backgroundColor = NSColor.black.cgColor
    placeholder.dimLayer.opacity = 0
    placeholder.layer?.addSublayer(placeholder.dimLayer)
    placeholder.cards.frame = placeholder.bounds
    placeholder.cards.alphaValue = 0
    placeholder.addSubview(placeholder.cards)
    win.contentView = placeholder
    captureBackdrop(screen: screen, into: placeholder)
    FileManager.default.createFile(atPath: activeFlag, contents: nil)
    rememberFront()
    tlog("show: screen=\(win.frame) mouse=\(NSEvent.mouseLocation) winNum=\(win.windowNumber)")
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(placeholder)
    slpsFocus(pid: getpid(), wid: UInt32(win.windowNumber))
    DispatchQueue.global().async {
        let snap = snapshotWorkspaces()
        DispatchQueue.main.async {
            guard overlayVisible, let c = win.contentView as? ContentView else { return }
            buildOverlay(snap, into: c)
        }
    }
}

var lastShowAt = Date.distantPast
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler {
    tlog("SIGUSR1 visible=\(overlayVisible)")
    if overlayVisible {
        // lift-off noise after the opening swipe can re-fire the
        // vertical gesture — a close-toggle within 1.2s of showing is
        // not a human asking to close
        if Date().timeIntervalSince(lastShowAt) > 1.2 { hideOverlay() }
    } else {
        lastShowAt = Date()
        showOverlay()
    }
}
usr1.resume()

// losing key (cmd-tab away) hides — an overview you can't see anymore
// must not linger as an invisible key window
NotificationCenter.default.addObserver(
    forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { _ in
    let front = NSWorkspace.shared.frontmostApplication
    tlog("didResignKey -> frontmost now: \(front?.localizedName ?? "?") pid=\(front?.processIdentifier ?? -1)")
    hideOverlay()
}

if showOnLaunch {
    DispatchQueue.main.async { showOverlay() }
}
app.run()
