// omacosy-overview — the workspace overview Mission Control can't be.
// AeroSpace workspaces aren't Spaces, so MC shows one undifferentiated
// window pile; this overlay asks AeroSpace itself and draws a card per
// non-empty workspace: real app icons + window titles, the focused
// workspace ringed in the theme accent. Click a card or press its
// digit to switch; Esc, a click on the backdrop, or invoking again
// (the 4-finger swipe up) dismisses.
//
// One-shot process by design: launched per invocation (fast — one
// aerospace CLI round-trip), exits on dismiss. A second launch finds
// the lockfile and kills the first: swipe up twice = toggle.
import AppKit

// --- single-instance toggle ---------------------------------------------

let lockPath = "/tmp/omacosy-overview-\(getuid()).pid"
if let old = try? String(contentsOfFile: lockPath, encoding: .utf8),
    let pid = pid_t(old.trimmingCharacters(in: .whitespacesAndNewlines)),
    kill(pid, 0) == 0 {
    kill(pid, SIGTERM)
    try? FileManager.default.removeItem(atPath: lockPath)
    exit(0)
}
try? "\(getpid())".write(toFile: lockPath, atomically: true, encoding: .utf8)
func cleanupAndExit() -> Never {
    try? FileManager.default.removeItem(atPath: lockPath)
    exit(0)
}
signal(SIGTERM) { _ in cleanupAndExit() }

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
    let app: String
    let title: String
    let bundle: String
}

var wins: [String: [Win]] = [:] // workspace id -> windows
for line in aerospace(["list-windows", "--all", "--format",
    "%{workspace}\t%{app-name}\t%{window-title}\t%{app-bundle-path}"]).split(separator: "\n") {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 4, !f[0].isEmpty else { continue }
    wins[f[0], default: []].append(Win(app: f[1], title: f[2], bundle: f[3]))
}
let focused = aerospace(["list-workspaces", "--focused"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
// non-empty workspaces plus the focused one, in aerospace order
let allWs = aerospace(["list-workspaces", "--all"]).split(separator: "\n").map(String.init)
let shown = allWs.filter { wins[$0] != nil || $0 == focused }
guard !shown.isEmpty else { cleanupAndExit() }

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
let accent = themeAccent()

// --- UI ------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// overlay on the screen the cursor is on
let mouse = NSEvent.mouseLocation
let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
let win = KeyWindow(contentRect: screen.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
win.level = .popUpMenu
win.isOpaque = false
win.backgroundColor = NSColor.black.withAlphaComponent(0.72)
win.hasShadow = false
win.animationBehavior = .none
win.collectionBehavior = [.canJoinAllSpaces, .stationary]

func switchTo(_ ws: String) {
    _ = aerospace(["workspace", ws])
    cleanupAndExit()
}

// card geometry
let cardW: CGFloat = 300
let rowH: CGFloat = 30
let headH: CGFloat = 44
let cardPad: CGFloat = 10
let maxRows = 8
func cardH(_ n: Int) -> CGFloat { headH + CGFloat(min(n, maxRows)) * rowH + cardPad }
let cols = min(shown.count, shown.count <= 4 ? shown.count : 3)
let gap: CGFloat = 24

final class ContentView: NSView {
    var cardRects: [(NSRect, String)] = []
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, ws) in cardRects where r.contains(p) {
            switchTo(ws)
        }
        cleanupAndExit() // backdrop click dismisses
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cleanupAndExit() } // esc
        if let ch = event.charactersIgnoringModifiers, shown.contains(ch) {
            switchTo(ch)
        }
    }
}

let content = ContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
content.wantsLayer = true
win.contentView = content

func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

// grid layout, centered
let rowsOfCards = stride(from: 0, to: shown.count, by: cols).map {
    Array(shown[$0..<min($0 + cols, shown.count)])
}
let gridH = rowsOfCards.reduce(-gap) { acc, row in
    acc + gap + row.map { cardH(wins[$0]?.count ?? 0) }.max()!
}
var y = (screen.frame.height + gridH) / 2 // top edge, descending
for row in rowsOfCards {
    let rowW = CGFloat(row.count) * cardW + CGFloat(row.count - 1) * gap
    let rowMaxH = row.map { cardH(wins[$0]?.count ?? 0) }.max()!
    var x = (screen.frame.width - rowW) / 2
    for ws in row {
        let items = wins[ws] ?? []
        let h = cardH(items.count)
        let rect = NSRect(x: x, y: y - h, width: cardW, height: h)
        let card = NSView(frame: rect)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        card.layer?.cornerRadius = 12
        if ws == focused {
            card.layer?.borderColor = accent.cgColor
            card.layer?.borderWidth = 2
        }
        let num = label(ws, size: 22, weight: .bold,
            color: ws == focused ? accent : NSColor(calibratedWhite: 0.85, alpha: 1))
        num.frame = NSRect(x: 16, y: h - 36, width: cardW - 32, height: 26)
        card.addSubview(num)
        for (i, w) in items.prefix(maxRows).enumerated() {
            let ry = h - headH - CGFloat(i + 1) * rowH + 4
            let icon = NSImageView(frame: NSRect(x: 16, y: ry, width: 22, height: 22))
            icon.image = NSWorkspace.shared.icon(forFile: w.bundle)
            card.addSubview(icon)
            let title = w.title.isEmpty ? w.app : w.title
            let t = label(title, size: 13, weight: .regular,
                color: NSColor(calibratedWhite: 0.75, alpha: 1))
            t.frame = NSRect(x: 46, y: ry + 2, width: cardW - 62, height: 18)
            card.addSubview(t)
        }
        if items.count > maxRows {
            let more = label("+\(items.count - maxRows) more", size: 12, weight: .regular,
                color: NSColor(calibratedWhite: 0.45, alpha: 1))
            more.frame = NSRect(x: 46, y: 6, width: cardW - 62, height: 16)
            card.addSubview(more)
        }
        content.addSubview(card)
        content.cardRects.append((rect, ws))
        x += cardW + gap
    }
    y -= rowMaxH + gap
}

let hint = label("click / 1-9 to switch · esc or swipe up to close",
    size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.5, alpha: 1))
hint.alignment = .center
hint.frame = NSRect(x: 0, y: max((screen.frame.height - gridH) / 2 - 44, 12),
    width: screen.frame.width, height: 18)
content.addSubview(hint)

win.makeKeyAndOrderFront(nil)
win.makeFirstResponder(content)
app.activate(ignoringOtherApps: true)
// losing key (cmd-tab away, another overlay) dismisses — an overview
// you can't see anymore shouldn't linger as an invisible key window
NotificationCenter.default.addObserver(
    forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { _ in
    cleanupAndExit()
}
app.run()
