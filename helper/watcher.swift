// omacosy-watcher — system events → sketchybar triggers. The bar
// polls only where macOS publishes nothing (weather, the clock);
// everything with a real publisher lands here instead: one resident
// subscriber that pokes the bar the moment state actually changes.
//
//   windows_changed — SkyLight window create/destroy: the workspace
//     strip's single-app icons follow opens/closes instantly
//     (replaces the spaces_observer 10s poll)
//
// launchd agent com.omacosy.watcher; log at /tmp/omacosy-watcher.log
import AppKit

// --- SkyLight notifications (borders.swift recipe) -----------------------

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

let EVENT_WINDOW_MOVE: UInt32 = 806
let EVENT_WINDOW_CREATE: UInt32 = 1325
let EVENT_WINDOW_DESTROY: UInt32 = 1326

// --- plumbing ------------------------------------------------------------

let logURL = URL(fileURLWithPath: "/tmp/omacosy-watcher.log")
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

let sketchybarBin = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "sketchybar"

func trigger(_ event: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: sketchybarBin)
    p.arguments = ["--trigger", event]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

// --- windows_changed -----------------------------------------------------

// window churn arrives in bursts (one app open spawns several server
// windows; a drag emits a move per frame; aerospace stashes windows
// offscreen to change workspaces, which is also a move). TRAILING
// debounce coalesces every burst into one bar pass after it settles.
var pendingWindows: DispatchWorkItem?
func kickWindows() {
    pendingWindows?.cancel()
    let work = DispatchWorkItem { trigger("windows_changed") }
    pendingWindows = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
}

let cid = SLSMainConnectionID()
let slsCallback: NotifyProc = { _, _, _, _ in kickWindows() }
for code in [EVENT_WINDOW_CREATE, EVENT_WINDOW_DESTROY, EVENT_WINDOW_MOVE] {
    _ = SLSRegisterNotifyProc(slsCallback, code, nil)
}
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
    tlog("SLSGetEventPort failed — window events unavailable")
}

tlog("omacosy-watcher up")
RunLoop.current.run()
