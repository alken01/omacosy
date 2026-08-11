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

let pollSeconds = 0.08
let dwellTicks = 2

var lastKey = ""
var pendingKey = ""
var pendingTicks = 0

func displayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
}

func topWindowUnder(_ p: CGPoint) -> (pid: pid_t, key: String)? {
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
        // AeroSpace hides inactive-workspace windows mostly offscreen
        // with a sliver visible — ignore anything <30% on-screen
        let visible = screens.reduce(CGFloat(0)) { acc, scr in
            let i = rect.intersection(scr)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        if rect.width * rect.height > 0, visible / (rect.width * rect.height) < 0.3 {
            continue
        }
        return (pid, "\(pid):\(num)")
    }
    return nil
}

func focus(pid: pid_t, at p: CGPoint) {
    // element under the cursor -> its window -> make it main
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success,
        let el = element {
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef) == .success {
            let win = winRef as! AXUIElement
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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
    if hit.key == lastKey { pendingTicks = 0; return }
    if hit.key == pendingKey {
        pendingTicks += 1
        if pendingTicks >= dwellTicks {
            focus(pid: hit.pid, at: e.location)
            lastKey = hit.key
            pendingTicks = 0
        }
    } else {
        pendingKey = hit.key
        pendingTicks = 1
    }
}
RunLoop.current.add(timer, forMode: .common)
RunLoop.current.run()
