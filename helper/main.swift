// omacosy-helper — tiny compiled utility replacing four brew dependencies
// (cliclick, desktoppr, switchaudio-osx, blueutil):
//   cursor                  print the cursor position as "x,y" (CG top-left)
//   displays                per display (arrangement order): "index<TAB>notched"
//   wallpaper <path>        set the desktop picture on every screen
//   audio list              output devices: "*<TAB>name" (current) / "-<TAB>name"
//   audio set <name>        make <name> the default output device
//   bt power                print bluetooth power state (0/1)
//   bt power <on|off|toggle>
//   bt devices              paired devices: "<1|0 connected><TAB>address<TAB>name<TAB>kind"
//                           kind is a coarse class-of-device keyword
//                           (headphones/speaker/mic/keyboard/pointer/
//                           combo/phone/watch/device) for popup icons
//   bt connect <address> / bt disconnect <address>
//   input-age               seconds since the last deliberate user input
//                           (keys/clicks/scroll), for the focus guard
//   brightness              print the built-in display's brightness (0-100)
//   brightness set <0-100>  set it (DisplayServices — built-in/Apple
//                           displays only; external DDC is out of scope)
//   nightshift              print night shift state (on/off)
//   nightshift <on|off|toggle>
//   capslock off            clear the HID-system caps-lock latch (with the
//                           key remapped to Super, a latched LED is
//                           otherwise permanent)
// Built by install.sh with swiftc (present wherever Homebrew is).
// Bluetooth subcommands need the Bluetooth privacy permission of the
// *responsible* process (sketchybar, for bar plugins).
import AppKit
import CoreAudio
import IOBluetooth
import IOKit.hidsystem

// private but stable power API — the same symbols blueutil links
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func BTGetPower() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
func BTSetPower(_ state: Int32)

// DisplayServices (private) — the same calls Control Center makes;
// covers the built-in panel and Apple externals
@_silgen_name("DisplayServicesGetBrightness")
func DSGetBrightness(_ display: CGDirectDisplayID, _ value: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("DisplayServicesSetBrightness")
func DSSetBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Int32

func builtinDisplayID() -> CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return CGMainDisplayID() }
    for i in 0..<Int(n) where CGDisplayIsBuiltin(ids[i]) != 0 {
        return ids[i]
    }
    return CGMainDisplayID()
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// --- CoreAudio ---------------------------------------------------------

func audioProperty(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioDeviceID {
    var addr = audioProperty(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func outputDevices() -> [AudioDeviceID] {
    var addr = audioProperty(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
        var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize = UInt32(0)
        AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
        return streamsSize > 0
    }
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = audioProperty(kAudioObjectPropertyName)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    withUnsafeMutablePointer(to: &name) { ptr in
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return name as String
}

// --- dispatch ----------------------------------------------------------

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "cursor":
    guard let e = CGEvent(source: nil) else { exit(1) }
    print("\(Int(e.location.x)),\(Int(e.location.y))")

case "displays":
    // arrangement-ordered (left to right, matching AeroSpace/sketchybar
    // numbering): "<index><TAB><1 if notched else 0>"
    let screens = NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    for (i, scr) in screens.enumerated() {
        let notched = scr.safeAreaInsets.top > 0 ? 1 : 0
        print("\(i + 1)\t\(notched)")
    }

case "wallpaper":
    guard args.count > 2 else { fail("usage: wallpaper <path>") }
    let url = URL(fileURLWithPath: args[2])
    var failures = 0
    for screen in NSScreen.screens {
        do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
        catch { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)

case "nightshift":
    // CBBlueLightClient (private CoreBrightness) — what Control Center
    // itself calls. Only the leading `active`/`enabled` fields of the
    // status struct are read; the rest is layout padding per the OSS
    // `nightlight` tool.
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
        let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
    else { fail("nightshift: CoreBrightness unavailable") }
    let client = cls.init()
    struct BLStatus {
        var active: ObjCBool = false
        var enabled: ObjCBool = false
        var sunSchedulePermitted: ObjCBool = false
        var mode: Int32 = 0
        var schedule: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
        var disableFlags: UInt64 = 0
        var available: ObjCBool = false
    }
    func blEnabled() -> Bool {
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let m = class_getInstanceMethod(cls, sel) else { return false }
        typealias GetFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let f = unsafeBitCast(method_getImplementation(m), to: GetFn.self)
        var st = BLStatus()
        _ = withUnsafeMutablePointer(to: &st) { f(client, sel, UnsafeMutableRawPointer($0)) }
        return st.enabled.boolValue
    }
    func blSet(_ on: Bool) {
        let sel = NSSelectorFromString("setEnabled:")
        guard let m = class_getInstanceMethod(cls, sel) else { fail("nightshift: setEnabled missing") }
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let f = unsafeBitCast(method_getImplementation(m), to: SetFn.self)
        _ = f(client, sel, on)
    }
    switch args.count > 2 ? args[2] : "status" {
    case "on": blSet(true)
    case "off": blSet(false)
    case "toggle": blSet(!blEnabled())
    case "status": break
    default: fail("usage: nightshift [on|off|toggle]")
    }
    print(blEnabled() ? "on" : "off")

case "capslock":
    guard args.count > 2, args[2] == "off" else { fail("usage: capslock off") }
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    var conn: io_connect_t = 0
    guard IOServiceOpen(svc, mach_task_self_, UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS
    else { fail("capslock: IOHIDSystem open failed") }
    guard IOHIDSetModifierLockState(conn, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS
    else { fail("capslock: set failed") }
    IOServiceClose(conn)

case "brightness":
    let display = builtinDisplayID()
    if args.count > 3, args[2] == "set" {
        guard let pct = Int(args[3]), (0...100).contains(pct) else {
            fail("usage: brightness set <0-100>")
        }
        guard DSSetBrightness(display, Float(pct) / 100.0) == 0 else {
            fail("brightness: set failed (unsupported display?)")
        }
    }
    var level: Float = -1
    guard DSGetBrightness(display, &level) == 0, level >= 0 else {
        fail("brightness: unreadable (unsupported display?)")
    }
    print(Int((level * 100).rounded()))

case "input-age":
    // seconds since the last DELIBERATE user input (keys, clicks,
    // scroll — not mouse motion). The focus guard uses this to tell a
    // user-driven workspace switch from an app yanking focus to
    // itself.
    let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown,
        .otherMouseDown, .scrollWheel]
    let age = types
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? .infinity
    print(String(format: "%.2f", age))

case "audio":
    let sub = args.count > 2 ? args[2] : "list"
    if sub == "list" {
        let current = defaultOutputDevice()
        for id in outputDevices() {
            print("\(id == current ? "*" : "-")\t\(deviceName(id))")
        }
    } else if sub == "set", args.count > 3 {
        guard let id = outputDevices().first(where: { deviceName($0) == args[3] }) else {
            fail("audio: no output device named '\(args[3])'")
        }
        var addr = audioProperty(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &dev) == noErr else {
            fail("audio: failed to set default output")
        }
    } else {
        fail("usage: audio list | audio set <name>")
    }

case "bt":
    let sub = args.count > 2 ? args[2] : ""
    switch sub {
    case "power":
        if args.count > 3 {
            let want: Int32
            switch args[3] {
            case "on": want = 1
            case "off": want = 0
            case "toggle": want = BTGetPower() == 0 ? 1 : 0
            default: fail("usage: bt power [on|off|toggle]")
            }
            BTSetPower(want)
            // the preference call is async; give it a moment
            for _ in 0..<20 where BTGetPower() != want { usleep(100_000) }
        }
        print(BTGetPower())
    case "devices":
        // Coarse class-of-device keyword from the CoD major/minor
        // fields (Bluetooth Assigned Numbers). Only buckets the popup
        // can pick an icon for — everything else is "device".
        func kind(_ d: IOBluetoothDevice) -> String {
            switch d.deviceClassMajor {
            case 0x04: // audio/video
                switch d.deviceClassMinor {
                case 0x04: return "mic"
                case 0x05, 0x07, 0x08, 0x0A: return "speaker" // loudspeaker / portable / car / hifi
                default: return "headphones" // headset / hands-free / headphones
                }
            case 0x05: // peripheral: bits 4-5 of the minor field
                switch d.deviceClassMinor & 0x30 {
                case 0x10: return "keyboard"
                case 0x20: return "pointer"
                case 0x30: return "combo"
                default: return "device"
                }
            case 0x02: return "phone"
            case 0x07: return "watch"
            default: return "device"
            }
        }
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            let name = d.name ?? "unknown"
            let addr = d.addressString ?? "?"
            print("\(d.isConnected() ? 1 : 0)\t\(addr)\t\(name)\t\(kind(d))")
        }
    case "connect", "disconnect":
        guard args.count > 3 else { fail("usage: bt \(sub) <address>") }
        guard let d = IOBluetoothDevice(addressString: args[3]) else { fail("bt: bad address") }
        let status = sub == "connect" ? d.openConnection() : d.closeConnection()
        exit(status == kIOReturnSuccess ? 0 : 1)
    default:
        fail("usage: bt power [on|off|toggle] | bt devices | bt connect <addr> | bt disconnect <addr>")
    }

default:
    fail("usage: omacosy-helper cursor | displays | wallpaper <path> | audio ... | bt ... | brightness [set <0-100>] | input-age")
}
