// omacosy-watcher — system events → sketchybar triggers. The bar
// polls only where macOS publishes nothing (weather, the clock);
// everything with a real publisher lands here instead: one resident
// subscriber that pokes the bar the moment state actually changes.
//
//   windows_changed  — SkyLight window create/destroy/move: the
//     workspace strip's single-app icons follow opens/closes/moves
//     (replaced the spaces_observer 10s poll)
//   bluetooth_change — IOBluetooth connect/disconnect + CoreBluetooth
//     power state (replaced the pill's 30s poll). Needs the Bluetooth
//     privacy grant; skipped cleanly when denied.
//   net_change       — SCDynamicStore network state: IP / default
//     route / link changes (replaced the wifi pill's 30s poll)
//   battery_change   — IOPS power-source notifications, which fire on
//     capacity changes too (replaced the 120s poll)
//   spotify_change   — NSWorkspace app launch/quit for Spotify; the
//     bar already gets PlaybackStateChanged from Spotify itself, this
//     covers the capsule appearing/vanishing (replaced the 60s poll)
//
// launchd agent com.omacosy.watcher; log at /tmp/omacosy-watcher.log
import AppKit
import CoreBluetooth
import IOBluetooth
import IOKit.ps
import SystemConfiguration

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

// Every source chatters in bursts (one app open spawns several server
// windows; a drag emits a move per frame; IOPS repeats itself), so
// each event name gets a TRAILING debounce: one bar pass after the
// burst settles.
var pending: [String: DispatchWorkItem] = [:]
func kick(_ event: String, after delay: Double) {
    pending[event]?.cancel()
    let work = DispatchWorkItem { trigger(event) }
    pending[event] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
}

// --- windows_changed -----------------------------------------------------
// (move matters: aerospace changes workspaces by stashing windows
// offscreen — a move, not a create; a drag collapses to one trigger
// at its end thanks to the trailing debounce)

let cid = SLSMainConnectionID()
let slsCallback: NotifyProc = { _, _, _, _ in kick("windows_changed", after: 0.3) }
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

// --- bluetooth_change ----------------------------------------------------
// IOBluetooth ABORTS the process when called without the Bluetooth
// privacy grant, so gate on CBCentralManager.authorization (reading it
// never prompts). .notDetermined → instantiate a central to raise the
// system prompt once, and start the classic notifications when the
// grant lands; denied → skip bluetooth, the rest still runs.

final class BTWatcher: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var classicStarted = false

    func start() {
        tlog("bluetooth: authorization=\(CBCentralManager.authorization.rawValue) (0=undetermined 1=restricted 2=denied 3=allowed)")
        switch CBCentralManager.authorization {
        case .allowedAlways:
            startClassic()
            // a central is still wanted: its delegate publishes
            // power-on/off flips (Control Center toggles)
            central = CBCentralManager(delegate: self, queue: .main)
        case .denied, .restricted:
            tlog("bluetooth: permission denied — bluetooth_change disabled")
        default: // .notDetermined — prompt, then start from the delegate
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    private func startClassic() {
        guard !classicStarted else { return }
        classicStarted = true
        IOBluetoothDevice.register(forConnectNotifications: self,
                                   selector: #selector(deviceConnected(_:device:)))
        // devices already connected at launch still need their
        // disconnects watched
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        where d.isConnected() {
            d.register(forDisconnectNotification: self,
                       selector: #selector(deviceDisconnected(_:device:)))
        }
        tlog("bluetooth: classic notifications up")
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self,
                        selector: #selector(deviceDisconnected(_:device:)))
        kick("bluetooth_change", after: 0.5)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        kick("bluetooth_change", after: 0.5)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBCentralManager.authorization == .allowedAlways { startClassic() }
        kick("bluetooth_change", after: 0.5)
    }
}
let btWatcher = BTWatcher()
btWatcher.start()

// --- net_change ----------------------------------------------------------

var scContext = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
if let store = SCDynamicStoreCreate(nil, "omacosy-watcher" as CFString,
                                    { _, _, _ in kick("net_change", after: 1.0) }, &scContext) {
    SCDynamicStoreSetNotificationKeys(store, nil, [
        "State:/Network/Global/IPv4",
        "State:/Network/Interface/en.*/Link",
        "State:/Network/Interface/en.*/AirPort",
    ] as CFArray)
    if let src = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
    }
} else {
    tlog("SCDynamicStoreCreate failed — net_change disabled")
}

// --- battery_change ------------------------------------------------------
// IOPS notifies on every power-source change, capacity ticks included

let psCallback: IOPowerSourceCallbackType = { _ in kick("battery_change", after: 2.0) }
if let src = IOPSNotificationCreateRunLoopSource(psCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
} else {
    tlog("IOPSNotificationCreateRunLoopSource failed — battery_change disabled")
}

// --- spotify_change ------------------------------------------------------
// Spotify broadcasts PlaybackStateChanged itself (the bar listens
// directly); launch/quit is the one transition it can't announce

let wsnc = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.didLaunchApplicationNotification,
             NSWorkspace.didTerminateApplicationNotification] {
    wsnc.addObserver(forName: name, object: nil, queue: .main) { n in
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == "com.spotify.client" else { return }
        kick("spotify_change", after: 0.5)
    }
}

tlog("omacosy-watcher up")
RunLoop.current.run()
