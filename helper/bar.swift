// omacosy-bar — a native bar surface, in ONE process.
//
// SLICE: workspace chips + front-app pill, on the built-in display only,
// drawn over sketchybar's own bar so the two can be watched side by side
// (sketchybar keeps the external display). This exists to answer one
// question with numbers rather than opinion: how much of the bar's
// latency is the work, and how much is the process boundaries?
//
// The shape of the answer is in the data flow. sketchybar learns that a
// workspace changed, forks a shell script, and that script spawns five
// `aerospace` CLI calls (~23 ms each) to ask what happened — 220 ms
// before a pixel moves. This daemon already holds the window model in
// memory, fed by the same SkyLight notifications the other daemons use,
// so a workspace switch touches no subprocess at all: update one field,
// draw one frame. The slow path (which windows exist, where) runs only
// on window create/destroy, off the critical path.
//
// Timings land in /tmp/omacosy-bar.log as `switch <ws> <ms>`.
import AppKit

// --- SkyLight window events (borders.swift recipe) ------------------------

typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32
@_silgen_name("SLSRegisterNotifyProc")
func SLSRegisterNotifyProc(_ proc: NotifyProc, _ event: UInt32, _ context: UnsafeMutableRawPointer?) -> CGError
@_silgen_name("SLSGetEventPort")
func SLSGetEventPort(_ cid: Int32, _ port: UnsafeMutablePointer<mach_port_t>) -> CGError
@_silgen_name("SLEventCreateNextEvent")
func SLEventCreateNextEvent(_ cid: Int32) -> Unmanaged<CGEvent>?

let EVENT_WINDOW_CREATE: UInt32 = 1325
let EVENT_WINDOW_DESTROY: UInt32 = 1326

// --- plumbing -------------------------------------------------------------

let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"

@discardableResult
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

let logURL = URL(fileURLWithPath: "/tmp/omacosy-bar.log")
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

// --- theme ----------------------------------------------------------------
// The same palette sketchybar reads. Parsed once and kept as colours, not
// re-sourced per item by sixteen shell scripts.

struct Palette {
    var itemBG = NSColor.black
    var accent = NSColor.systemBlue
    var label = NSColor.white
    var muted = NSColor.gray
    var barBG = NSColor.black
}

func color(fromARGB v: UInt64) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: CGFloat((v >> 24) & 0xff) / 255)
}

func loadPalette() -> Palette {
    var p = Palette()
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omarchy/current/theme/sketchybar.sh")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return p }
    for line in text.split(separator: "\n") {
        let parts = line.replacingOccurrences(of: "export ", with: "").split(separator: "=")
        guard parts.count == 2, parts[1].hasPrefix("0x"),
              let v = UInt64(parts[1].dropFirst(2), radix: 16) else { continue }
        switch parts[0] {
        case "ITEM_BG": p.itemBG = color(fromARGB: v)
        case "ACCENT": p.accent = color(fromARGB: v)
        case "LABEL_COLOR": p.label = color(fromARGB: v)
        case "MUTED": p.muted = color(fromARGB: v)
        case "BAR_BG_SOLID": p.barBG = color(fromARGB: v)
        default: break
        }
    }
    return p
}

// Ask for the family by name and VERIFY we got it. sketchybar's
// `--default` silently handed half the bar "Hack Nerd Font", which is not
// installed, so the text fell back to a system face and nothing said so.
// A missing family is a loud fallback here, once, at startup.
func nerdFont(_ face: String, _ size: CGFloat) -> NSFont {
    let desc = NSFontDescriptor(fontAttributes: [
        .family: "JetBrainsMono Nerd Font",
        .face: face,
    ])
    if let f = NSFont(descriptor: desc, size: size), f.familyName == "JetBrainsMono Nerd Font" {
        return f
    }
    tlog("font: JetBrainsMono Nerd Font \(face) unavailable — using system mono")
    return .monospacedSystemFont(ofSize: size, weight: face == "Bold" ? .bold : .semibold)
}

// --- model ----------------------------------------------------------------

final class Model {
    var workspaces: [String] = [] // this monitor's set, in order
    var mine: Set<String> = []
    var focused = "" // globally focused workspace
    var visible = "" // visible on THIS monitor
    var soleApp: [String: String] = [:] // ws -> app name, when it holds exactly one
    var occupied: Set<String> = []
    var frontApp = ""
}

let model = Model()
var palette = loadPalette()

// aerospace monitor id for the display this bar lives on
var monitorID = "2"

// SLOW path: who lives where. Three CLI calls — and it runs only when a
// window is created or destroyed, never on a workspace switch.
//
// It is computed OFF the main queue and applied on it. Measured the hard
// way: with the CLI calls inline on main, one contended rebuild blocked
// the render path for 7.6 seconds and every switch queued behind it. The
// architecture only pays off if subprocess work never sits on the path a
// frame has to travel.
struct Snapshot {
    var workspaces: [String] = []
    var visible = ""
    var soleApp: [String: String] = [:]
    var occupied: Set<String> = []
}

let rebuildQueue = DispatchQueue(label: "com.omacosy.bar.rebuild")

func fetchSnapshot() -> Snapshot {
    var s = Snapshot()
    s.workspaces = aerospace(["list-workspaces", "--monitor", monitorID])
        .split(separator: "\n").map(String.init)
    s.visible = aerospace(["list-workspaces", "--monitor", monitorID, "--visible"])
        .split(separator: "\n").map(String.init).first ?? ""

    var sole: [String: String] = [:]
    var count: [String: Int] = [:]
    for line in aerospace(["list-windows", "--all", "--format",
                           "%{workspace}|%{app-name}|%{window-layout}"]).split(separator: "\n") {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, f[2] != "floating" else { continue }
        s.occupied.insert(f[0])
        if let existing = sole[f[0]] {
            if existing != f[1] { count[f[0]] = 2 }
        } else {
            sole[f[0]] = f[1]
            count[f[0]] = 1
        }
    }
    s.soleApp = sole.filter { count[$0.key] == 1 }
    return s
}

func apply(_ s: Snapshot) {
    if !s.workspaces.isEmpty {
        model.workspaces = s.workspaces
        model.mine = Set(s.workspaces)
    }
    if !s.visible.isEmpty { model.visible = s.visible }
    model.occupied = s.occupied
    model.soleApp = s.soleApp
}

// FAST path: a workspace switch changes focus and nothing else. No CLI,
// no IPC, no shell — the model already knows the rest.
func setFocused(_ ws: String) {
    model.focused = ws
    if model.mine.contains(ws) { model.visible = ws }
}

// --- view -----------------------------------------------------------------

// Icons come from the running app and are cached by name: a redraw must
// not walk the process list.
var iconCache: [String: NSImage] = [:]
func appIcon(_ name: String) -> NSImage? {
    if let cached = iconCache[name] { return cached }
    guard let icon = NSWorkspace.shared.runningApplications
        .first(where: { $0.localizedName == name })?.icon else { return nil }
    iconCache[name] = icon
    return icon
}

let barHeight: CGFloat = 34
let padLeft: CGFloat = 10
let chipBox: CGFloat = 20
let chipPad: CGFloat = 2
let pillHeight: CGFloat = 26
let chipPillHeight: CGFloat = 20
let radius: CGFloat = 4
let gap: CGFloat = 14

final class BarView: NSView {
    var chipRects: [(String, NSRect)] = []

    override var isFlipped: Bool { false }

    private func draw(_ s: String, _ font: NSFont, _ color: NSColor, centeredIn box: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let at = NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
        (s as NSString).draw(at: at, withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        chipRects.removeAll()
        let chipFont = nerdFont("SemiBold", 13)
        let appFont = nerdFont("Bold", 13)

        // workspace chips, in one bracket
        // Same rule as the bar: an empty GUEST workspace (the two-digit
        // set that force-assignment parks here while undocked) is noise,
        // but an empty primary keeps its slot so the row stays 1..9.
        let shown = model.workspaces.filter {
            $0.count == 1 || model.occupied.contains($0) || $0 == model.focused
        }
        let bracketW = CGFloat(shown.count) * (chipBox + chipPad * 2)
        let bracket = NSRect(x: padLeft, y: (barHeight - pillHeight) / 2,
                             width: bracketW, height: pillHeight)
        palette.itemBG.setFill()
        NSBezierPath(roundedRect: bracket, xRadius: radius, yRadius: radius).fill()

        var x = padLeft
        for ws in shown {
            let slot = NSRect(x: x, y: 0, width: chipBox + chipPad * 2, height: barHeight)
            let box = slot.insetBy(dx: chipPad, dy: 0)
            if ws == model.focused {
                let pill = NSRect(x: box.minX, y: (barHeight - chipPillHeight) / 2,
                                  width: chipBox, height: chipPillHeight)
                palette.accent.setFill()
                NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            }
            let tint: NSColor = ws == model.focused ? palette.barBG
                : (ws == model.visible ? palette.label : palette.muted)
            // a workspace holding exactly one app shows that app's icon —
            // free here, where NSRunningApplication hands the icon over,
            // versus sketchybar's image-registration dance
            if let app = model.soleApp[ws], let icon = appIcon(app) {
                icon.draw(in: NSRect(x: box.midX - 9, y: barHeight / 2 - 9, width: 18, height: 18))
            } else {
                draw(String(ws.suffix(1)), chipFont, tint, centeredIn: box)
            }
            chipRects.append((ws, slot))
            x += chipBox + chipPad * 2
        }

        // front-app pill
        guard !model.frontApp.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: appFont, .foregroundColor: palette.accent]
        let textW = (model.frontApp as NSString).size(withAttributes: attrs).width
        let pill = NSRect(x: bracket.maxX + gap, y: (barHeight - pillHeight) / 2,
                          width: textW + 20, height: pillHeight)
        palette.itemBG.setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
        draw(model.frontApp, appFont, palette.accent, centeredIn: pill)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = chipRects.first(where: { $0.1.contains(p) })?.0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { aerospace(["workspace", hit]) }
    }
}

// --- window ---------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// the built-in display: this slice runs here while sketchybar keeps the
// external one, so both are on screen at once for comparison
func builtinScreen() -> NSScreen? {
    NSScreen.screens.first {
        guard let n = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return CGDisplayIsBuiltin(n.uint32Value) != 0
    }
}

// The aerospace monitor id is NOT stable across a hotplug: undock and the
// built-in stops being monitor 2 and becomes monitor 1, at which point a
// cached id returns "Invalid monitor ID" and the snapshot comes back
// empty — the bar then renders the last set it knew, silently stale.
// Resolve the id by display NAME every time the screens change.
func targetScreen() -> NSScreen? { builtinScreen() ?? NSScreen.main }

func resolveMonitor() {
    guard let screen = targetScreen() else { return }
    for line in aerospace(["list-monitors", "--format", "%{monitor-id}|%{monitor-name}"]).split(separator: "\n") {
        let f = line.split(separator: "|").map(String.init)
        if f.count == 2, f[1] == screen.localizedName, f[0] != monitorID {
            tlog("monitor: \(screen.localizedName) is now aerospace monitor \(f[0]) (was \(monitorID))")
            monitorID = f[0]
        }
    }
}

guard let screen = targetScreen() else {
    FileHandle.standardError.write("omacosy-bar: no usable display\n".data(using: .utf8)!)
    exit(1)
}
resolveMonitor()

// AppKit pushes an ordinary window down out of the menu-bar strip, which
// is exactly where a bar belongs — 32 px lower than asked for, measured.
// Opting out of the constraint is the supported way to sit in it.
final class BarWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// While this is a comparison slice, sit one bar-height BELOW sketchybar's
// strip so both are readable at once instead of overdrawing each other.
// OMACOSY_BAR_TOP=1 puts it where a real bar belongs.
let stackOffset: CGFloat = ProcessInfo.processInfo.environment["OMACOSY_BAR_TOP"] == nil ? barHeight : 0
let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight - stackOffset,
                   width: screen.frame.width, height: barHeight)
let win = BarWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.hasShadow = false
win.level = .statusBar // sketchybar's own windows sit at layer -20
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
let view = BarView(frame: NSRect(origin: .zero, size: frame.size))
win.contentView = view
win.orderFrontRegardless()

func repaint() {
    // every caller is already on the main queue; display() is synchronous
    // so the timings below cover real drawing, not just invalidation
    MainActor.assumeIsolated {
        view.needsDisplay = true
        view.display()
    }
}

// --- signals --------------------------------------------------------------

// Workspace switches arrive as a one-line file written by aerospace's
// exec-on-workspace-change hook (a bash builtin redirect — no extra
// process). A regular file, deliberately: a FIFO with no reader would
// block the hook and wedge workspace switching if this daemon died.
// borders.swift's watcher, same reasons: .attrib catches a symlink swap
// that .write alone misses, and a delete/rename re-arms instead of going
// deaf for the rest of the daemon's life.
func watch(_ path: String, create: Bool, handler: @escaping () -> Void) {
    if create, !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { watch(path, create: create, handler: handler) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { watch(path, create: create, handler: handler) }
    }
    src.resume()
}

let wsPath = "/tmp/omacosy-bar-ws"
watch(wsPath, create: true) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard let text = try? String(contentsOfFile: wsPath, encoding: .utf8) else { return }
    let ws = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ws.isEmpty, ws != model.focused else { return }
    setFocused(ws)
    repaint()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    tlog(String(format: "switch %@ %.2f ms", ws, ms))
}

// front app: a notification, not a poll and not a script
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let name = app.localizedName, name != model.frontApp,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    model.frontApp = name
    repaint()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    tlog(String(format: "frontapp %@ %.2f ms", name, ms))
}

// Displays come and go: re-resolve which aerospace monitor this screen is
// now, move the window onto it, and rebuild. Screen parameters arrive
// before the arrangement settles, so give it a beat (borders.swift learnt
// the same lesson with a stale CG-to-Cocoa flip after a replug).
func placeWindow() {
    guard let screen = targetScreen() else { return }
    MainActor.assumeIsolated {
        win.setFrame(NSRect(x: screen.frame.minX,
                            y: screen.frame.maxY - barHeight - stackOffset,
                            width: screen.frame.width, height: barHeight), display: true)
        view.frame = NSRect(origin: .zero, size: win.frame.size)
    }
}

NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        resolveMonitor()
        placeWindow()
        kickRebuild()
    }
}

// window create/destroy: the only thing that needs the slow path, and it
// is debounced off the critical path
var pending: DispatchWorkItem?
func kickRebuild() {
    pending?.cancel()
    let w = DispatchWorkItem {
        rebuildQueue.async {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let snapshot = fetchSnapshot()
            let fetched = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            DispatchQueue.main.async {
                let t1 = DispatchTime.now().uptimeNanoseconds
                apply(snapshot)
                repaint()
                let drawn = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000
                tlog(String(format: "rebuild fetch %.2f ms (off-main) + paint %.2f ms", fetched, drawn))
            }
        }
    }
    pending = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
}

let cid = SLSMainConnectionID()
let notify: NotifyProc = { _, _, _, _ in DispatchQueue.main.async { kickRebuild() } }
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_CREATE, nil)
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_DESTROY, nil)
var eventPort: mach_port_t = 0
if SLSGetEventPort(cid, &eventPort).rawValue == 0, eventPort != 0 {
    let drain = DispatchSource.makeMachReceiveSource(port: eventPort, queue: .main)
    drain.setEventHandler { while let e = SLEventCreateNextEvent(SLSMainConnectionID()) { e.release() } }
    drain.resume()
}

// theme switches: repaint, never rebuild. theme-set swaps the symlink
// inside this directory; the file behind the old one never changes itself.
watch(FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omarchy/current").path, create: false) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    palette = loadPalette()
    iconCache.removeAll()
    repaint()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    tlog(String(format: "theme %.2f ms", ms))
}

// --- go -------------------------------------------------------------------

model.frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
model.focused = aerospace(["list-workspaces", "--focused"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
apply(fetchSnapshot()) // blocking is fine here: the run loop has not started
repaint()
tlog("omacosy-bar up on \(screen.localizedName) (aerospace monitor \(monitorID))")
app.run()
