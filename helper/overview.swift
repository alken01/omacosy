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

let pidPath = "/tmp/omacosy-overview-\(getuid()).pid"
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

var thumbs: [UInt32: CGImage] = [:]
var thumbViews: [UInt32: NSImageView] = [:]

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
            guard let img = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg) else { continue }
            await MainActor.run {
                thumbs[wid] = img
                if let v = thumbViews[wid] {
                    v.image = NSImage(cgImage: img, size: .zero)
                }
            }
        }
    }
}

// --- UI ------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let accent = themeAccent()

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

var shownIds: [String] = []
var overlayVisible = false

let win = KeyWindow(contentRect: NSScreen.main!.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
win.level = .popUpMenu
win.isOpaque = false
win.backgroundColor = NSColor.black.withAlphaComponent(0.72)
win.hasShadow = false
win.animationBehavior = .none
win.collectionBehavior = [.canJoinAllSpaces, .stationary]

func hideOverlay() {
    guard overlayVisible else { return }
    overlayVisible = false
    win.orderOut(nil)
    NSApp.deactivate()
}

func switchTo(_ ws: String) {
    hideOverlay()
    DispatchQueue.global().async { _ = aerospace(["workspace", ws]) }
}

final class ContentView: NSView {
    var cardRects: [(NSRect, String)] = []
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, ws) in cardRects where r.contains(p) {
            switchTo(ws)
            return
        }
        hideOverlay()
    }
    override func keyDown(with event: NSEvent) {
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

func buildOverlay(_ snap: (order: [String], wins: [String: [Win]], focused: String)) {
    let (order, wins, focused) = snap
    let shown = order.filter { wins[$0] != nil || $0 == focused }
    guard !shown.isEmpty else { return }
    shownIds = shown
    thumbViews.removeAll()

    let screen = win.screen ?? NSScreen.main!
    let content = ContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
    content.wantsLayer = true
    win.contentView = content

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
                let sv = NSImageView(frame: slot)
                sv.wantsLayer = true
                sv.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
                sv.layer?.cornerRadius = 6
                sv.layer?.masksToBounds = true
                sv.imageScaling = .scaleProportionallyUpOrDown
                if let t = thumbs[w.id] {
                    sv.image = NSImage(cgImage: t, size: .zero)
                } else {
                    sv.image = NSWorkspace.shared.icon(forFile: w.bundle)
                    sv.imageScaling = .scaleNone
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
            content.addSubview(card)
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
    content.addSubview(hint)

    win.makeFirstResponder(content)
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
    win.contentView = placeholder
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(placeholder)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.global().async {
        let snap = snapshotWorkspaces()
        DispatchQueue.main.async {
            guard overlayVisible else { return }
            buildOverlay(snap)
        }
    }
}

let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler { overlayVisible ? hideOverlay() : showOverlay() }
usr1.resume()

// losing key (cmd-tab away) hides — an overview you can't see anymore
// must not linger as an invisible key window
NotificationCenter.default.addObserver(
    forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { _ in
    hideOverlay()
}

if showOnLaunch {
    DispatchQueue.main.async { showOverlay() }
}
app.run()
