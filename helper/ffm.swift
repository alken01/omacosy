// omacosy-ffm — focus follows mouse for the omacosy tiling setup.
// Polls the cursor (no permission needed), hit-tests the topmost normal
// window beneath it, and focuses that window via the Accessibility API
// (needs an Accessibility grant for this binary). Focus only — windows
// aren't explicitly raised; app activation reorders z, which is
// irrelevant while everything tiles without overlap.
//
// Deliberately boring: no focus changes while any mouse button is down
// (drags), a two-tick dwell before switching (no flicker when crossing
// windows), and only layer-0 windows count (menus, popups and the bar
// never steal focus).
import AppKit
import ApplicationServices

// Private SkyLight focus — the route AeroSpace and yabai use. The AX
// attributes politely no-op for some apps (Arc: every call returns
// success, nothing happens); SLPS actually moves focus.
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
    _ = SLPSSetFrontProcess(&psn, wid, 0x200) // kCPSUserGenerated
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

// Apps that hover must never focus (omarchy's JetBrains-style
// no_follow_mouse). One app name per line, # comments.
let ignoredApps: Set<String> = {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omacosy/ffm-ignore")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}()

let pollSeconds = 0.08
let dwellTicks = 1

var lastKey = ""
var pendingKey = ""
var pendingTicks = 0
var lastFocusAt = 0.0

func displayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
}

func topWindowUnder(_ p: CGPoint) -> (pid: pid_t, key: String, rect: CGRect, wid: UInt32)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return nil }
    let screens = displayBounds()
    for w in list { // list is front-to-back
        guard (w["kCGWindowLayer"] as? Int) == 0,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            let pid = w["kCGWindowOwnerPID"] as? pid_t,
            let num = w["kCGWindowNumber"] as? Int
        else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        guard rect.contains(p) else { continue }
        // topmost window is ignore-listed: leave focus alone entirely
        // (don't fall through to the window beneath)
        if let owner = w["kCGWindowOwnerName"] as? String,
            ignoredApps.contains(owner.lowercased()) {
            return nil
        }
        // AeroSpace hides inactive-workspace windows mostly offscreen
        // with a sliver visible — ignore anything <30% on-screen
        let visible = screens.reduce(CGFloat(0)) { acc, scr in
            let i = rect.intersection(scr)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        if rect.width * rect.height > 0, visible / (rect.width * rect.height) < 0.3 {
            continue
        }
        return (pid, "\(pid):\(num)", rect, UInt32(num))
    }
    return nil
}

// Focus exactly the window our filtered hit-test chose: find the AX
// window whose frame matches the CG rect. Never re-hit-test via AX —
// AXUIElementCopyElementAtPosition does its own unfiltered lookup and
// returns AeroSpace's offscreen-stashed slivers, causing focus loops.
let debug = ProcessInfo.processInfo.environment["OMACOSY_FFM_DEBUG"] != nil
func dbg(_ m: String) {
    if debug { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }
}

func focus(pid: pid_t, rect: CGRect) {
    let app = AXUIElementCreateApplication(pid)
    var matched = false
    var winsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
        let wins = winsRef as? [AXUIElement] {
        for win in wins {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success
            else { continue }
            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            dbg("  ax win pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height))) vs cg=(\(Int(rect.origin.x)),\(Int(rect.origin.y))) \(Int(rect.width))x\(Int(rect.height))")
            if abs(pos.x - rect.origin.x) < 2, abs(pos.y - rect.origin.y) < 2,
                abs(size.width - rect.width) < 2, abs(size.height - rect.height) < 2 {
                // raise first — Chromium apps often ignore main/frontmost
                // without it; z-order changes are moot in tiling
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                let r = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                dbg("  -> matched, set main: \(r.rawValue)")
                matched = true
                break
            }
        }
    }
    let fr = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    dbg("focus pid=\(pid) matched=\(matched) frontmost=\(fr.rawValue)")
}

guard AXIsProcessTrustedWithOptions(
    ["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
    FileHandle.standardError.write("omacosy-ffm: waiting for Accessibility permission…\n".data(using: .utf8)!)
    // poll until granted, then continue
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
    exit(2) // relaunch (launchd KeepAlive) so the grant applies cleanly
}

let timer = Timer(timeInterval: pollSeconds, repeats: true) { _ in
    // never move focus mid-drag
    if CGEventSource.buttonState(.combinedSessionState, button: .left)
        || CGEventSource.buttonState(.combinedSessionState, button: .right) {
        pendingTicks = 0
        return
    }
    guard let e = CGEvent(source: nil) else { return }
    guard let hit = topWindowUnder(e.location) else { pendingTicks = 0; return }
    // judge "already focused" by reality, not our own bookkeeping — a
    // silently failed focus attempt must be retried, not remembered
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    if hit.pid == frontPid && hit.key == lastKey { pendingTicks = 0; return }
    if hit.key == pendingKey {
        pendingTicks += 1
        if pendingTicks >= dwellTicks {
            // cooldown: never two focus changes within 400ms — breaks any
            // residual feedback loop with the window manager (250ms)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastFocusAt > 0.25 {
                slpsFocus(pid: hit.pid, wid: hit.wid)
                focus(pid: hit.pid, rect: hit.rect)
                lastFocusAt = now
                lastKey = hit.key
            }
            pendingTicks = 0
        }
    } else {
        pendingKey = hit.key
        pendingTicks = 1
    }
}
RunLoop.current.add(timer, forMode: .common)
RunLoop.current.run()
