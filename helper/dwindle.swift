// omacosy-dwindle — Hyprland's dwindle layout, grafted onto AeroSpace.
// AeroSpace inserts a new window as a SIBLING of the focused one, so a
// third window makes three equal columns; omarchy's dwindle splits the
// focused window's own rectangle instead, spiraling. This daemon
// closes that gap: when a new tiled window lands as the third-or-later
// sibling, it is joined into the previously focused window's slot —
// `join-with left` in an h_tiles container, `join-with up` in v_tiles
// (the previous sibling sits before the new one). AeroSpace's
// opposite-orientation normalization then alternates the nesting, and
// the spiral falls out. Validated by hand before automation:
// 3 windows -> H[A, V[B, C]]; 4th -> H[A, V[B, H[C, D]]].
//
// Stand-downs: the overview overlay's truce flag, floating windows,
// workspaces with fewer than 3 windows, and the opt-out file
// ~/.config/omacosy/no-dwindle. Events only — a missed event never
// triggers a late layout jump (settle refreshes its own bookkeeping,
// and only a FRESH window id may be acted on).
import AppKit

// --- SkyLight window-create events (borders.swift recipe) ---------------

typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32
@_silgen_name("SLSRegisterNotifyProc")
func SLSRegisterNotifyProc(_ proc: NotifyProc, _ event: UInt32, _ context: UnsafeMutableRawPointer?) -> CGError
@_silgen_name("SLSGetEventPort")
func SLSGetEventPort(_ cid: Int32, _ port: UnsafeMutablePointer<mach_port_t>) -> CGError
@_silgen_name("SLEventCreateNextEvent")
func SLEventCreateNextEvent(_ cid: Int32) -> Unmanaged<CGEvent>?
@_silgen_name("_CFMachPortSetOptions")
func _CFMachPortSetOptions(_ port: CFMachPort, _ options: Int32)

let EVENT_WINDOW_CREATE: UInt32 = 1325

// --- plumbing ------------------------------------------------------------

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

let logURL = URL(fileURLWithPath: "/tmp/omacosy-dwindle.log")
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

let overlayFlag = "/tmp/omacosy-overlay-active-\(getuid())"
let optOut = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omacosy/no-dwindle").path

func allWindowIds() -> Set<String> {
    Set(aerospace(["list-windows", "--all", "--format", "%{window-id}"])
        .split(separator: "\n").map(String.init))
}

var known = allWindowIds()

// --- the act -------------------------------------------------------------

func settle() {
    let current = allWindowIds()
    let fresh = current.subtracting(known)
    known = current
    guard !fresh.isEmpty else { return }
    guard !FileManager.default.fileExists(atPath: optOut),
        !FileManager.default.fileExists(atPath: overlayFlag) else { return }
    let f = aerospace(["list-windows", "--focused", "--format",
        "%{window-id}\t%{window-layout}\t%{window-parent-container-layout}\t%{workspace}"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count >= 4, fresh.contains(f[0]), f[1] != "floating" else { return }
    let wsCount = aerospace(["list-windows", "--workspace", f[3]])
        .split(separator: "\n").count
    guard wsCount >= 3 else { return } // a pair is already a 50/50 split
    // Orientation is set EXPLICITLY on the fresh nest (opposite of
    // the parent) — Hyprland's force_split-at-birth. The config's
    // opposite-orientation normalization used to do this implicitly,
    // but it re-derived orientations continuously, which turned
    // Super+J's local pair-flip into a whole-tree cascade; it is off
    // now (preserve_split=true equivalent) and birth is the one
    // moment orientation gets decided.
    switch f[2] {
    // `eval` takes both commands in ONE round trip. The saving is
    // small (a spawn is ~23ms and eval's is ~31ms, so ~14ms net) but
    // the join and the relayout also stop being two separate moments
    // the tiler can be observed between.
    case "h_tiles":
        _ = aerospace(["eval", "join-with left; layout v_tiles"])
        tlog("dwindle: joined \(f[0]) left→v (ws \(f[3]), \(wsCount) windows)")
    case "v_tiles":
        _ = aerospace(["eval", "join-with up; layout h_tiles"])
        tlog("dwindle: joined \(f[0]) up→h (ws \(f[3]), \(wsCount) windows)")
    default:
        break // accordions and exotics are the user's own arrangement
    }
}

// debounced: a create event fires before aerospace has tiled the
// window; give it a beat, and coalesce burst-opens into one pass.
// settle() spawns several aerospace CLI processes (each a blocking
// waitUntilExit) — a serial queue keeps that off the main thread so
// the SLS event drain never stalls behind a wedged aerospace, while
// still serializing settles against each other.
let settleQueue = DispatchQueue(label: "com.omacosy.dwindle.settle")
var pending: DispatchWorkItem? = nil
// 0.25s was three quarters of the visible artifact. Measured with a
// SkyLight probe: the create event arrives 36ms before AeroSpace
// touches a frame and its first layout finishes ~138ms after, so the
// tree this reads is settled well inside 120ms — and the second layout
// then lands close enough to the first to read as one rearrangement
// rather than two. It still coalesces an app that opens several
// windows at once, which is what the debounce is actually for.
let settleDelay = 0.12
func kick() {
    pending?.cancel()
    let work = DispatchWorkItem { settle() }
    pending = work
    settleQueue.asyncAfter(deadline: .now() + settleDelay, execute: work)
}

// --- event wiring --------------------------------------------------------

let cid = SLSMainConnectionID()
let callback: NotifyProc = { _, _, _, _ in kick() }
_ = SLSRegisterNotifyProc(callback, EVENT_WINDOW_CREATE, nil)

let portCallback: CFMachPortCallBack = { _, _, _, _ in
    while let e = SLEventCreateNextEvent(SLSMainConnectionID()) { e.release() }
}
var eventPort: mach_port_t = 0
if SLSGetEventPort(cid, &eventPort).rawValue == 0,
    let machPort = CFMachPortCreateWithPort(nil, eventPort, portCallback, nil, nil) {
    _CFMachPortSetOptions(machPort, 0x40)
    let source = CFMachPortCreateRunLoopSource(nil, machPort, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
} else {
    tlog("SLSGetEventPort failed — create events unavailable")
}

// No heartbeat: settle() refreshes `known` on every run, and the
// focused-must-be-fresh guard already blocks a stale diff from
// firing a late layout jump. (The old 5s timer was inert anyway —
// its pending-is-idle condition was permanently false after the
// first event — and reviving it would mean an aerospace process
// spawn every 5s forever, against the events-first doctrine.)
tlog("omacosy-dwindle up")
RunLoop.current.run()
