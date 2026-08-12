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
// Focus follows mouse MOVEMENT, not hover position (Hyprland
// semantics): a focus change may only fire within this window after
// the cursor last moved. A stationary cursor never steals focus — a
// freshly launched window (System Settings…) that self-activates
// under an idle pointer keeps its focus instead of being deactivated
// mid-launch, which is what made it vanish behind the tiles.
let moveEpsilonPx: CGFloat = 2
let moveGraceSeconds = 0.3

var lastKey = ""
var pendingKey = ""
var pendingTicks = 0
var lastFocusAt = 0.0
var lastCursor = CGPoint(x: -1_000_000, y: -1_000_000)
var lastMoveAt = 0.0

func displayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
}

func topWindowUnder(_ p: CGPoint) -> (pid: pid_t, key: String, rect: CGRect, wid: UInt32, covered: Bool)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return nil }
    let screens = displayBounds()
    // Front-to-back candidates that pass the same filters as the
    // hit-test, kept in z-order so "does anything in front overlap the
    // hit" is a prefix scan. (Side effect vs the old single pass: an
    // ignore-listed offscreen-stashed sliver no longer blocks focus —
    // it's filtered before the ignore check, which is the behaviour we
    // always wanted.)
    var cands: [(pid: pid_t, num: Int, rect: CGRect, owner: String)] = []
    for w in list { // list is front-to-back
        guard (w["kCGWindowLayer"] as? Int) == 0,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            let pid = w["kCGWindowOwnerPID"] as? pid_t,
            let num = w["kCGWindowNumber"] as? Int
        else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        // AeroSpace hides inactive-workspace windows mostly offscreen
        // with a sliver visible — ignore anything <30% on-screen
        let visible = screens.reduce(CGFloat(0)) { acc, scr in
            let i = rect.intersection(scr)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        if rect.width * rect.height > 0, visible / (rect.width * rect.height) < 0.3 {
            continue
        }
        cands.append((pid, num, rect, (w["kCGWindowOwnerName"] as? String) ?? ""))
    }
    for (i, c) in cands.enumerated() {
        guard c.rect.contains(p) else { continue }
        // topmost window is ignore-listed: leave focus alone entirely
        // (don't fall through to the window beneath)
        if ignoredApps.contains(c.owner.lowercased()) { return nil }
        // Anything in front of the hit that overlaps it is a floating
        // window (tiles never overlap): raising the hit would drag it
        // over the float. The caller then focuses WITHOUT raise, which
        // is what keeps floats always-in-front, omarchy style. Sub-4px
        // overlaps don't count (border / shadow slop).
        let covered = cands[..<i].contains { f in
            let o = f.rect.intersection(c.rect)
            return !o.isNull && o.width > 4 && o.height > 4
        }
        return (c.pid, "\(c.pid):\(c.num)", c.rect, UInt32(c.num), covered)
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

// `allowRaise: false` = the hovered window sits under a floating
// window somewhere on screen; focus it (SLPS + AXMain make it key)
// but leave z-order alone so the float stays in front — omarchy's
// float layer, emulated. Raising still happens when it's visually a
// no-op (nothing in front overlaps), which keeps the Chromium
// focus-needs-raise workaround for plain tile-to-tile hops.
func focus(pid: pid_t, rect: CGRect, allowRaise: Bool) {
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
                // without it; z-order changes are moot BETWEEN tiles
                // (they don't overlap), but skipped when a float is in
                // front (allowRaise == false)
                if allowRaise {
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                }
                let r = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                dbg("  -> matched, set main: \(r.rawValue)")
                matched = true
                break
            }
        }
    }
    // App-level activation raises the app's key window too, so it is
    // gated with the raise; the SLPS focus above already moved key
    // focus (it's the route that works even where AX no-ops).
    if allowRaise {
        let fr = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        dbg("focus pid=\(pid) matched=\(matched) frontmost=\(fr.rawValue)")
    } else {
        dbg("focus pid=\(pid) matched=\(matched) no-raise (float in front)")
    }
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
    let now = CFAbsoluteTimeGetCurrent()
    if abs(e.location.x - lastCursor.x) > moveEpsilonPx
        || abs(e.location.y - lastCursor.y) > moveEpsilonPx {
        lastMoveAt = now
    }
    lastCursor = e.location
    if now - lastMoveAt > moveGraceSeconds { pendingTicks = 0; return }
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
                focus(pid: hit.pid, rect: hit.rect, allowRaise: !hit.covered)
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
