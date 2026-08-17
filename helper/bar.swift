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
//
// The right cluster is the same eight pills the bar already carries, but
// reading their sources directly instead of forking a script that forks
// `pmset`, `osascript`, `networksetup` and `ipconfig`: IOPS for power,
// CoreAudio for volume, DisplayServices for brightness, SCDynamicStore
// for the network, IOBluetooth for devices. Every one of those is a
// publisher, so nothing here polls except the clock and the weather,
// which have no publisher to listen to.
import AppKit
import CoreAudio
import CoreBluetooth
import CoreWLAN
import IOBluetooth
import IOKit.ps
import SystemConfiguration

// DisplayServices (private) — the same calls Control Center makes, and
// the same ones helper/main.swift uses for `omacosy-helper brightness`.
@_silgen_name("DisplayServicesGetBrightness")
func DSGetBrightness(_ display: CGDirectDisplayID, _ value: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("DisplayServicesSetBrightness")
func DSSetBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Int32

// Brightness has a publisher after all. The callback's later arguments
// are deliberately untyped and never dereferenced: the arity is what the
// ABI needs, the contents are not ours to trust.
typealias DSBrightnessProc = @convention(c) (UnsafeRawPointer?, CGDirectDisplayID, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
@_silgen_name("DisplayServicesRegisterForBrightnessChangeNotifications")
func DSRegisterBrightnessNotifications(_ display: CGDirectDisplayID, _ context: UnsafeMutableRawPointer?, _ callback: DSBrightnessProc) -> Int32

@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func BTGetPower() -> Int32

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
    var red = NSColor.systemRed
    var green = NSColor.systemGreen
    var yellow = NSColor.systemYellow
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
        case "RED": p.red = color(fromARGB: v)
        case "GREEN": p.green = color(fromARGB: v)
        case "YELLOW": p.yellow = color(fromARGB: v)
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

// --- right cluster ---------------------------------------------------------
// An item is data. Layout, hit-testing and drawing are generic over the
// list, so adding a pill is one entry and one provider — no per-item
// geometry, no padding arithmetic, no width caches.

struct BarItem: Equatable {
    var icon = ""
    var label = ""
    var iconColor: NSColor?
    var drawing = true
}

// screen order, left to right
let rightOrder = ["weather", "wifi", "bluetooth", "brightness", "volume", "battery", "clock", "activity"]
var rightItems: [String: BarItem] = [:]

func set(_ name: String, _ mutate: (inout BarItem) -> Void) {
    var item = rightItems[name] ?? BarItem()
    mutate(&item)
    guard item != rightItems[name] else { return } // no pixels owed
    let t0 = DispatchTime.now().uptimeNanoseconds
    rightItems[name] = item
    repaint()
    tlog(String(format: "item %@ %.2f ms", name, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))
}

func shell(_ launch: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: out, encoding: .utf8) ?? ""
}

// --- clock (no publisher: the one honest timer, aligned to the minute)
func updateClock() {
    let f = DateFormatter()
    f.dateFormat = "EEE dd MMM  HH:mm"
    set("clock") { $0.icon = "󰃰"; $0.label = f.string(from: Date()) }
}

// --- battery (IOPS publishes, capacity ticks included)
func updateBattery() {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return }
    for source in list {
        guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey] as? Int else { continue }
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // same thresholds and glyphs the bar already uses
        var icon = "󰂃", color = palette.red
        switch pct {
        case 90...: icon = "󰁹"; color = palette.green
        case 60..<90: icon = "󰂀"; color = palette.label
        case 30..<60: icon = "󰁾"; color = palette.label
        case 10..<30: icon = "󰁻"; color = palette.yellow
        default: break
        }
        if charging { icon = "󰂄"; color = palette.green }
        set("battery") { $0.icon = icon; $0.iconColor = color; $0.label = "\(pct)%" }
        return
    }
}

// --- volume (CoreAudio publishes on the device itself)
func defaultOutputDevice() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioDevicePropertyScopeOutput, mElement: element)
}

func readVolume() -> (percent: Int, muted: Bool)? {
    let dev = defaultOutputDevice()
    guard dev != 0 else { return nil }

    var muted: UInt32 = 0
    var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &muteSize, &muted)

    var level: Float32 = 0
    var addr = volumeAddress(kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Float32>.size)
    if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &level) != noErr {
        // a device without a master channel: average the stereo pair
        var sum: Float32 = 0
        var found = 0
        for channel in UInt32(1)...UInt32(2) {
            var chAddr = volumeAddress(channel)
            var chSize = UInt32(MemoryLayout<Float32>.size)
            var value: Float32 = 0
            if AudioObjectGetPropertyData(dev, &chAddr, 0, nil, &chSize, &value) == noErr {
                sum += value
                found += 1
            }
        }
        guard found > 0 else { return nil }
        level = sum / Float32(found)
    }
    return (Int((level * 100).rounded()), muted != 0)
}

func writeVolume(_ percent: Int) {
    let dev = defaultOutputDevice()
    guard dev != 0 else { return }
    var value = Float32(min(100, max(0, percent))) / 100
    let size = UInt32(MemoryLayout<Float32>.size)
    var addr = volumeAddress(kAudioObjectPropertyElementMain)
    if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) != noErr {
        for channel in UInt32(1)...UInt32(2) {
            var chAddr = volumeAddress(channel)
            AudioObjectSetPropertyData(dev, &chAddr, 0, nil, size, &value)
        }
    }
}

// the output devices the volume popup lists — the same enumeration
// helper/main.swift does for `omacosy-helper audio`, without the round trip
func audioOutputDevices() -> [(id: AudioDeviceID, name: String)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }

    var result: [(AudioDeviceID, String)] = []
    for id in ids {
        // output-capable only: a device with no output streams is a mic
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0
        else { continue }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var ok = false
        withUnsafeMutablePointer(to: &name) { ptr in
            ok = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr) == noErr
        }
        guard ok else { continue }
        result.append((id, name as String))
    }
    return result
}

func setDefaultOutputDevice(_ id: AudioDeviceID) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = id
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

func updateVolume() {
    guard let v = readVolume() else { return }
    let icon: String
    if v.muted || v.percent == 0 {
        icon = "󰝟"
    } else if v.percent >= 70 {
        icon = "󰕾"
    } else if v.percent >= 30 {
        icon = "󰖀"
    } else {
        icon = "󰕿"
    }
    set("volume") { $0.icon = icon; $0.iconColor = nil; $0.label = v.muted ? "mute" : "\(v.percent)%" }
}

// --- brightness (DisplayServices publishes; built-in panel only)
func builtinDisplayID() -> CGDirectDisplayID {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
}

func updateBrightness() {
    var value: Float = 0
    guard DSGetBrightness(builtinDisplayID(), &value) == 0, value.isFinite else {
        set("brightness") { $0.drawing = false } // hide rather than lie
        return
    }
    let pct = Int((value * 100).rounded())
    let icon = pct >= 66 ? "󰃠" : (pct >= 33 ? "󰃟" : "󰃞")
    set("brightness") { $0.drawing = true; $0.icon = icon; $0.iconColor = nil; $0.label = "\(pct)%" }
}

// --- wifi (SCDynamicStore publishes; SSID needs a subprocess, so it is
// fetched off-main and only when the network actually changed)
var wifiDevice = CWWiFiClient.shared().interface()?.interfaceName ?? "en0"

func updateWifi() {
    let powered = CWWiFiClient.shared().interface()?.powerOn() ?? false
    guard powered else {
        set("wifi") { $0.icon = "󰖪"; $0.iconColor = nil; $0.label = "off" }
        return
    }
    rebuildQueue.async {
        // CoreWLAN hands out the SSID only with Location permission; the
        // bar has always read it from ipconfig instead, so do the same
        let summary = shell("/usr/sbin/ipconfig", ["getsummary", wifiDevice])
        var ssid = ""
        for line in summary.split(separator: "\n") where line.contains(" SSID : ") {
            ssid = line.components(separatedBy: " SSID : ").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            break
        }
        let named = ssid.isEmpty || ssid.hasPrefix("<") ? "" : ssid
        DispatchQueue.main.async {
            set("wifi") { $0.icon = "󰖩"; $0.iconColor = nil; $0.label = named }
        }
    }
}

// --- bluetooth (IOBluetooth publishes connect/disconnect)
//
// IOBluetooth ABORTS the process outright — SIGABRT, no exception to
// catch — if it is touched without the Bluetooth privacy grant. Learnt
// here the same way watcher.swift learnt it: exit code 134 and an empty
// log. So the grant is gated on CBCentralManager.authorization (reading
// that never prompts), and the pill simply stays hidden when it is not
// held. The binary carries helper/bar-info.plist for the usage string,
// without which the prompt cannot even be raised.
func updateBluetooth() {
    guard CBCentralManager.authorization == .allowedAlways else { return }
    guard BTGetPower() != 0 else {
        set("bluetooth") { $0.drawing = true; $0.icon = "󰂲"; $0.iconColor = nil; $0.label = "off" }
        return
    }
    let connected = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
        .filter { $0.isConnected() }.count
    set("bluetooth") {
        $0.drawing = true
        $0.icon = connected > 0 ? "󰂱" : "󰂯"
        $0.iconColor = nil
        $0.label = connected > 0 ? "\(connected)" : ""
    }
}

// IOBluetooth's connect/disconnect notifications are ObjC target/action,
// so they need a real object to aim at; CoreBluetooth's delegate is what
// tells us the grant has landed.
final class BluetoothWatcher: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var classicStarted = false

    // Only ever touched with the grant already in hand. Creating a
    // CBCentralManager is itself an access, and TCC judges it by the
    // RESPONSIBLE process, not this binary: launched from a shell the
    // whole process is killed (SIGABRT, exit 134, no report), embedded
    // Info.plist and signature notwithstanding. watcher.swift gets away
    // with prompting because launchd starts it and is responsible for
    // it. So this never prompts — under launchd the grant is already
    // there and the pill appears; run by hand it stays hidden.
    func start() {
        switch CBCentralManager.authorization {
        case .allowedAlways:
            startClassic()
            central = CBCentralManager(delegate: self, queue: .main)
        default:
            tlog("bluetooth: no grant in this launch context — pill hidden")
            set("bluetooth") { $0.drawing = false }
        }
    }

    private func startClassic() {
        guard !classicStarted else { return }
        classicStarted = true
        IOBluetoothDevice.register(forConnectNotifications: self,
                                   selector: #selector(connected(_:device:)))
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        where device.isConnected() {
            device.register(forDisconnectNotification: self, selector: #selector(changed(_:device:)))
        }
        updateBluetooth()
    }

    @objc func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(changed(_:device:)))
        DispatchQueue.main.async { updateBluetooth() }
    }

    @objc func changed(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { updateBluetooth() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBCentralManager.authorization == .allowedAlways { startClassic() }
        DispatchQueue.main.async { updateBluetooth() }
    }
}
let bluetoothWatcher = BluetoothWatcher()

// --- weather (no publisher; wttr.in, refreshed on a long timer)
func updateWeather() {
    guard let url = URL(string: "https://wttr.in/?format=%c+%t") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data, var text = String(data: data, encoding: .utf8) else { return }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "+", with: "")
        guard !text.isEmpty, !text.lowercased().contains("unknown") else { return }
        DispatchQueue.main.async {
            set("weather") { $0.icon = ""; $0.label = text }
        }
    }.resume()
}

// --- popups ----------------------------------------------------------------
// A popup is a list of rows in its own window. sketchybar has to model
// these as bar items with a naming convention (`clock.cal.3`) that a
// separate shell guard greps to clean up; here they are just views that
// go away when the window closes, so there is no convention to break and
// nothing to leak.

struct PopupRow {
    var icon = ""
    var text = ""
    var hero = false // accent, bold — the title row
    var dim = false // the quiet action footer
    var highlight = false // today's week, the active device
    var slider: Double? // 0...1 draws a track instead of text
    var onSlide: ((Double) -> Void)?
    var action: (() -> Void)?
}

let rowHeight: CGFloat = 26
let popupPad: CGFloat = 8
let popupRadius: CGFloat = 8

final class PopupView: NSView {
    var rows: [PopupRow] = []
    private var rowRects: [(Int, NSRect)] = []

    override var isFlipped: Bool { true }

    func font(_ row: PopupRow) -> NSFont {
        if row.hero { return nerdFont("Bold", 13) }
        if row.dim { return nerdFont("Regular", 12) }
        return nerdFont("Regular", 13)
    }

    func color(_ row: PopupRow) -> NSColor {
        if row.hero { return palette.accent }
        // the dim footer is the label colour at 60%, the same relationship
        // the shell popups build with a 0x99 alpha prefix
        if row.dim { return palette.label.withAlphaComponent(0.6) }
        return palette.label
    }

    func measure() -> NSSize {
        var width: CGFloat = 0
        for row in rows {
            let attrs: [NSAttributedString.Key: Any] = [.font: font(row)]
            var w = (row.text as NSString).size(withAttributes: attrs).width
            if !row.icon.isEmpty {
                w += (row.icon as NSString).size(withAttributes: [.font: nerdFont("Bold", 13)]).width + 8
            }
            if row.slider != nil { w = max(w, 150) }
            width = max(width, w)
        }
        return NSSize(width: width + popupPad * 2 + 20,
                      height: CGFloat(rows.count) * rowHeight + popupPad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        rowRects.removeAll()
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: popupRadius, yRadius: popupRadius)
        palette.barBG.setFill()
        body.fill()
        palette.accent.setStroke()
        body.lineWidth = 1
        body.stroke()

        var y = popupPad
        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: popupPad, y: y, width: bounds.width - popupPad * 2, height: rowHeight)
            if row.highlight {
                palette.itemBG.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: 2), xRadius: 4, yRadius: 4).fill()
            }
            var x = rect.minX + 4
            if !row.icon.isEmpty {
                let iconAttrs: [NSAttributedString.Key: Any] =
                    [.font: nerdFont("Bold", 13), .foregroundColor: palette.accent]
                let size = (row.icon as NSString).size(withAttributes: iconAttrs)
                (row.icon as NSString).draw(at: NSPoint(x: x, y: rect.midY - size.height / 2),
                                            withAttributes: iconAttrs)
                x += size.width + 8
            }
            if let value = row.slider {
                // track, then filled portion — the readout is the row's text
                let trackW = rect.width - (x - rect.minX) - 52
                let track = NSRect(x: x, y: rect.midY - 3, width: trackW, height: 6)
                palette.itemBG.setFill()
                NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
                palette.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                 width: track.width * CGFloat(value), height: track.height),
                             xRadius: 3, yRadius: 3).fill()
                let attrs: [NSAttributedString.Key: Any] =
                    [.font: font(row), .foregroundColor: color(row)]
                let size = (row.text as NSString).size(withAttributes: attrs)
                (row.text as NSString).draw(
                    at: NSPoint(x: rect.maxX - size.width - 4, y: rect.midY - size.height / 2),
                    withAttributes: attrs)
            } else {
                let attrs: [NSAttributedString.Key: Any] =
                    [.font: font(row), .foregroundColor: color(row)]
                let size = (row.text as NSString).size(withAttributes: attrs)
                (row.text as NSString).draw(at: NSPoint(x: x, y: rect.midY - size.height / 2),
                                            withAttributes: attrs)
            }
            rowRects.append((index, rect))
            y += rowHeight
        }
    }


    // Tracking areas, not a poll and not a global monitor: a global
    // monitor stops delivering once this app is itself active, which is
    // exactly what clicking the bar makes it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { scheduleHullCheck() }

    private func slide(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (index, rect) = rowRects.first(where: { $0.1.contains(p) }),
              rows[index].slider != nil, let onSlide = rows[index].onSlide else { return }
        let trackX = rect.minX + 4
        let trackW = rect.width - 4 - 52
        onSlide(min(1, max(0, (p.x - trackX) / trackW)))
    }

    override func mouseDown(with event: NSEvent) { slide(event) }
    override func mouseDragged(with event: NSEvent) { slide(event) }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (index, _) = rowRects.first(where: { $0.1.contains(p) }),
              rows[index].slider == nil, let action = rows[index].action else { return }
        action()
    }
}

final class PopupWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

var popupWindow: PopupWindow?
var popupView: PopupView?
var openPopup: String? // which bar item owns it

func closePopup() {
    popupWindow?.orderOut(nil)
    popupWindow = nil
    popupView = nil
    openPopup = nil
}

// rows are rebuilt, not patched: the content is cheap to regenerate and a
// stale row is worse than a redrawn one
func refreshPopup() {
    guard let name = openPopup, let view = popupView, let window = popupWindow else { return }
    view.rows = popupRows(for: name)
    let size = view.measure()
    window.setContentSize(size)
    view.frame = NSRect(origin: .zero, size: size)
    view.needsDisplay = true
    view.display()
}

func showPopup(_ name: String, under anchor: NSRect) {
    if openPopup == name { closePopup(); return }
    closePopup()
    let rows = popupRows(for: name)
    guard !rows.isEmpty else { return }

    let view = PopupView(frame: .zero)
    view.rows = rows
    let size = view.measure()
    view.frame = NSRect(origin: .zero, size: size)

    // right-aligned under the item, clamped to the screen
    guard let screen = targetScreen() else { return }
    let barBottom = win.frame.minY
    var x = anchor.maxX - size.width
    x = min(max(screen.frame.minX + 6, x), screen.frame.maxX - size.width - 6)
    let window = PopupWindow(contentRect: NSRect(x: x, y: barBottom - size.height - 4,
                                                 width: size.width, height: size.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .popUpMenu
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.acceptsMouseMovedEvents = true
    window.contentView = view
    window.orderFrontRegardless()
    popupWindow = window
    popupView = view
    openPopup = name
}

// --- popup content ---------------------------------------------------------

func calendarRows() -> [PopupRow] {
    var rows: [PopupRow] = []
    let now = Date()
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2 // Monday, like the shell version
    let title = DateFormatter()
    title.dateFormat = "MMMM yyyy"
    rows.append(PopupRow(text: title.string(from: now).lowercased(), hero: true))
    rows.append(PopupRow(text: "mo tu we th fr sa su", dim: true))

    guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
          let range = cal.range(of: .day, in: .month, for: now) else { return rows }
    let today = cal.component(.day, from: now)
    // weekday index with Monday = 0
    let leading = (cal.component(.weekday, from: monthStart) + 5) % 7
    let prevDays = cal.range(of: .day, in: .month,
                             for: cal.date(byAdding: .month, value: -1, to: monthStart)!)!.count

    var cells: [(Int, Bool)] = [] // day, in-month
    for i in 0..<leading { cells.append((prevDays - leading + 1 + i, false)) }
    for d in range { cells.append((d, true)) }
    var next = 1
    while cells.count % 7 != 0 { cells.append((next, false)); next += 1 }

    for week in stride(from: 0, to: cells.count, by: 7) {
        let slice = cells[week..<min(week + 7, cells.count)]
        let text = slice.map { String(format: "%2d", $0.0) }.joined(separator: " ")
        let hasToday = slice.contains { $0.0 == today && $0.1 }
        rows.append(PopupRow(icon: hasToday ? "▸" : " ", text: text, highlight: hasToday))
    }
    let week = cal.component(.weekOfYear, from: now)
    rows.append(PopupRow(text: "week \(week)", dim: true))
    return rows
}

func brightnessRows() -> [PopupRow] {
    var value: Float = 0
    guard DSGetBrightness(builtinDisplayID(), &value) == 0 else { return [] }
    return [
        PopupRow(icon: "󰃟", text: "\(Int((value * 100).rounded()))%",
                 slider: Double(value),
                 onSlide: { fraction in
                     _ = DSSetBrightness(builtinDisplayID(), Float(fraction))
                     updateBrightness()
                     refreshPopup()
                 }),
        PopupRow(text: "display settings…", dim: true, action: {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
            closePopup()
        }),
    ]
}

func volumeRows() -> [PopupRow] {
    guard let v = readVolume() else { return [] }
    var rows: [PopupRow] = [
        PopupRow(icon: v.muted ? "󰝟" : "󰕾", text: v.muted ? "mute" : "\(v.percent)%",
                 slider: Double(v.percent) / 100,
                 onSlide: { fraction in
                     writeVolume(Int((fraction * 100).rounded()))
                     updateVolume()
                     refreshPopup()
                 }),
    ]
    // output devices, current one marked — the same list `omacosy-helper
    // audio` offers, read here without the round trip
    let current = defaultOutputDevice()
    for device in audioOutputDevices() {
        rows.append(PopupRow(icon: device.id == current ? "󰄬" : " ", text: device.name,
                             highlight: device.id == current,
                             action: {
                                 setDefaultOutputDevice(device.id)
                                 updateVolume()
                                 refreshPopup()
                             }))
    }
    rows.append(PopupRow(text: "sound settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        closePopup()
    }))
    return rows
}

func wifiRows() -> [PopupRow] {
    let interface = CWWiFiClient.shared().interface()
    var rows: [PopupRow] = [
        PopupRow(text: (rightItems["wifi"]?.label.isEmpty ?? true) ? "wi-fi" : rightItems["wifi"]!.label,
                 hero: true),
    ]
    rows.append(PopupRow(text: "ip \(shell("/usr/sbin/ipconfig", ["getifaddr", wifiDevice]).trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("none"))"))
    if let rssi = interface?.rssiValue(), rssi != 0 {
        let verdict = rssi >= -55 ? "excellent" : (rssi >= -67 ? "good" : (rssi >= -75 ? "fair" : "weak"))
        rows.append(PopupRow(text: "signal \(rssi) dBm  \(verdict)"))
    }
    if let channel = interface?.wlanChannel() {
        rows.append(PopupRow(text: "channel \(channel.channelNumber)"))
    }
    rows.append(PopupRow(text: "network settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
        closePopup()
    }))
    return rows
}

func bluetoothRows() -> [PopupRow] {
    var rows: [PopupRow] = [PopupRow(text: "bluetooth", hero: true)]
    guard CBCentralManager.authorization == .allowedAlways else {
        rows.append(PopupRow(text: "no permission in this launch context", dim: true))
        return rows
    }
    for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
        let name = device.name ?? device.addressString ?? "device"
        rows.append(PopupRow(icon: device.isConnected() ? "󰂱" : "󰂯", text: name,
                             highlight: device.isConnected(),
                             action: {
                                 if device.isConnected() { device.closeConnection() } else { device.openConnection() }
                                 updateBluetooth()
                                 refreshPopup()
                             }))
    }
    rows.append(PopupRow(text: "bluetooth settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        closePopup()
    }))
    return rows
}

func popupRows(for name: String) -> [PopupRow] {
    switch name {
    case "clock": return calendarRows()
    case "brightness": return brightnessRows()
    case "volume": return volumeRows()
    case "wifi": return wifiRows()
    case "bluetooth": return bluetoothRows()
    default: return []
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
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

// the terminal the activity pill opens btop in — the same apps.conf the
// bar and aerospace read, so one config still drives all of them
let terminalApp: String = {
    let config = URL(fileURLWithPath: (FileManager.default
        .destinationOfSymbolicLinkAtPathIfAny("\(NSHomeDirectory())/.config/sketchybar")))
        .deletingLastPathComponent().appendingPathComponent("apps.conf")
    guard let text = try? String(contentsOf: config, encoding: .utf8) else { return "Ghostty" }
    for line in text.split(separator: "\n") where line.hasPrefix("TERMINAL=") {
        return line.dropFirst("TERMINAL=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
    return "Ghostty"
}()

extension FileManager {
    func destinationOfSymbolicLinkAtPathIfAny(_ path: String) -> String {
        (try? destinationOfSymbolicLink(atPath: path)) ?? path
    }
}

final class BarView: NSView {
    var chipRects: [(String, NSRect)] = []
    var itemRects: [(String, NSRect)] = []

    override var isFlipped: Bool { false }

    private func draw(_ s: String, _ font: NSFont, _ color: NSColor, centeredIn box: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let at = NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
        (s as NSString).draw(at: at, withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        chipRects.removeAll()
        itemRects.removeAll()
        let chipFont = nerdFont("SemiBold", 13)
        let appFont = nerdFont("Bold", 13)
        let iconFont = nerdFont("Bold", 14)

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
        if !model.frontApp.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: appFont, .foregroundColor: palette.accent]
            let textW = (model.frontApp as NSString).size(withAttributes: attrs).width
            let pill = NSRect(x: bracket.maxX + gap, y: (barHeight - pillHeight) / 2,
                              width: textW + 20, height: pillHeight)
            palette.itemBG.setFill()
            NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            draw(model.frontApp, appFont, palette.accent, centeredIn: pill)
        }

        // right cluster: laid out from the right edge inwards, so a pill
        // changing width never shifts the ones outside it
        var cursor = bounds.maxX - padLeft
        for name in rightOrder.reversed() {
            guard let item = rightItems[name], item.drawing,
                  !(item.icon.isEmpty && item.label.isEmpty) else { continue }
            let iconAttrs: [NSAttributedString.Key: Any] =
                [.font: iconFont, .foregroundColor: item.iconColor ?? palette.label]
            let labelAttrs: [NSAttributedString.Key: Any] =
                [.font: chipFont, .foregroundColor: palette.label]
            let iconSize = (item.icon as NSString).size(withAttributes: iconAttrs)
            let labelSize = (item.label as NSString).size(withAttributes: labelAttrs)
            // icon.padding_left 10, icon-to-label 7, label.padding_right 10
            let width = 10 + iconSize.width + (item.label.isEmpty ? 10 : 7 + labelSize.width + 10)
            let pill = NSRect(x: cursor - width, y: (barHeight - pillHeight) / 2,
                              width: width, height: pillHeight)
            palette.itemBG.setFill()
            NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            (item.icon as NSString).draw(
                at: NSPoint(x: pill.minX + 10, y: pill.midY - iconSize.height / 2), withAttributes: iconAttrs)
            if !item.label.isEmpty {
                (item.label as NSString).draw(
                    at: NSPoint(x: pill.minX + 10 + iconSize.width + 7, y: pill.midY - labelSize.height / 2),
                    withAttributes: labelAttrs)
            }
            itemRects.append((name, NSRect(x: pill.minX, y: 0, width: width, height: barHeight)))
            cursor = pill.minX - gap
        }
    }


    // Tracking areas, not a poll and not a global monitor: a global
    // monitor stops delivering once this app is itself active, which is
    // exactly what clicking the bar makes it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { scheduleHullCheck() }

    private func hit(_ event: NSEvent) -> String? {
        let p = convert(event.locationInWindow, from: nil)
        return itemRects.first(where: { $0.1.contains(p) })?.0
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let ws = chipRects.first(where: { $0.1.contains(p) })?.0 {
            DispatchQueue.global(qos: .userInitiated).async { aerospace(["workspace", ws]) }
            return
        }
        guard let name = hit(event), let rect = itemRects.first(where: { $0.0 == name })?.1 else {
            closePopup()
            return
        }
        // an item with a popup toggles it; the rest still act directly
        if !popupRows(for: name).isEmpty {
            let anchor = window?.convertToScreen(convert(rect, to: nil)) ?? rect
            showPopup(name, under: anchor)
            return
        }
        closePopup()
        switch name {
        case "battery":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case "activity":
            DispatchQueue.global(qos: .userInitiated).async {
                _ = shell("/usr/bin/open", ["-na", terminalApp, "--args", "--title=omacosy-activity", "-e", "btop"])
            }
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let name = hit(event) else { return }
        let step = event.scrollingDeltaY > 0 ? 5 : -5
        switch name {
        case "volume":
            guard let v = readVolume() else { return }
            writeVolume(v.percent + step) // the CoreAudio listener repaints
        case "brightness":
            var value: Float = 0
            guard DSGetBrightness(builtinDisplayID(), &value) == 0 else { return }
            _ = DSSetBrightness(builtinDisplayID(), min(1, max(0, value + Float(step) / 100)))
            updateBrightness()
        default: break
        }
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
win.acceptsMouseMovedEvents = true // tracking areas need the moves
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

// --- popup guard -----------------------------------------------------------
// popup_guard.sh polls the cursor on a loop and greps item names to decide
// whether a popup should still be open. Here the cursor is a published
// event and the geometry is already known, so the rule is exact: a popup
// closes when the pointer is in neither the bar nor the popup — which is
// what "don't close it while I'm still in the bar" actually means.
// The check runs a beat after the pointer leaves either surface, because
// travelling from the bar to its popup crosses the gap between them and
// must not read as leaving.
func scheduleHullCheck() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        if popupWindow != nil, pointerLeftTheHull() { closePopup() }
    }
}

func pointerLeftTheHull() -> Bool {
    guard let popup = popupWindow else { return false }
    let p = NSEvent.mouseLocation
    let slack: CGFloat = 6 // the gap between the bar and the popup
    return !win.frame.insetBy(dx: 0, dy: -slack).contains(p)
        && !popup.frame.insetBy(dx: -slack, dy: -slack).contains(p)
}

// the monitor must be RETAINED — dropping the returned token deregisters
// it immediately, and the popup then never closes on its own
var popupGuardToken: Any?
popupGuardToken = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
    // a click that lands in another app dismisses the popup; hover-exit
    // is the tracking areas' job
    if popupWindow != nil, pointerLeftTheHull() { closePopup() }
}

// --- right-cluster publishers ---------------------------------------------

// battery: IOPS fires on capacity ticks too
let powerCallback: IOPowerSourceCallbackType = { _ in DispatchQueue.main.async { updateBattery() } }
if let src = IOPSNotificationCreateRunLoopSource(powerCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
} else {
    tlog("IOPSNotificationCreateRunLoopSource failed — battery pill will not update")
}

// volume: listen on the current default output device, and re-attach when
// the default changes (plugging in headphones is a different device)
var volumeListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

func attachVolumeListeners() {
    for (object, address, block) in volumeListeners {
        var a = address
        AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
    }
    volumeListeners.removeAll()

    let dev = defaultOutputDevice()
    guard dev != 0 else { return }
    let block: AudioObjectPropertyListenerBlock = { _, _ in updateVolume() }
    for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main, block) == noErr {
            volumeListeners.append((dev, addr, block))
        }
    }
    updateVolume()
}

var defaultDeviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                    &defaultDeviceAddress, DispatchQueue.main) { _, _ in
    attachVolumeListeners()
}
attachVolumeListeners()

// brightness: DisplayServices publishes, so the keyboard keys land here
// without the bar being told about them by anyone else
let brightnessProc: DSBrightnessProc = { _, _, _, _ in
    DispatchQueue.main.async { updateBrightness() }
}
if DSRegisterBrightnessNotifications(builtinDisplayID(), nil, brightnessProc) != 0 {
    tlog("brightness notifications unavailable — pill updates on scroll only")
}

// network: the same SCDynamicStore keys the watcher uses
var storeContext = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
if let store = SCDynamicStoreCreate(nil, "omacosy-bar" as CFString,
                                    { _, _, _ in DispatchQueue.main.async { updateWifi() } }, &storeContext) {
    SCDynamicStoreSetNotificationKeys(store, nil, [
        "State:/Network/Global/IPv4",
        "State:/Network/Interface/en.*/Link",
        "State:/Network/Interface/en.*/AirPort",
    ] as CFArray)
    if let src = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
    }
} else {
    tlog("SCDynamicStoreCreate failed — wifi pill will not update")
}

// bluetooth: gated on the privacy grant, which the watcher above also needs
bluetoothWatcher.start()

// clock and weather have no publisher to listen to. The clock ticks on
// the minute boundary rather than every 60 s from launch, so it never
// shows a stale minute.
func scheduleClock() {
    updateClock()
    let now = Date()
    let nextMinute = Calendar.current.date(bySetting: .second, value: 0,
                                           of: now.addingTimeInterval(60)) ?? now.addingTimeInterval(60)
    DispatchQueue.main.asyncAfter(deadline: .now() + max(1, nextMinute.timeIntervalSinceNow)) { scheduleClock() }
}
scheduleClock()

Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in updateWeather() }

// --- go -------------------------------------------------------------------

model.frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
model.focused = aerospace(["list-workspaces", "--focused"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
apply(fetchSnapshot()) // blocking is fine here: the run loop has not started
rightItems["activity"] = BarItem(icon: "󰍛", iconColor: palette.accent)
updateBattery()
updateBrightness()
updateWifi()
updateWeather()
repaint()
tlog("omacosy-bar up on \(screen.localizedName) (aerospace monitor \(monitorID))")
app.run()
