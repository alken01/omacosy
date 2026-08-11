// omacosy-helper — tiny compiled utility replacing two brew dependencies:
//   cursor            print the cursor position as "x,y" (CG top-left coords)
//   wallpaper <path>  set the desktop picture on every screen (the same
//                     NSWorkspace API desktoppr wraps; System Events
//                     scripting half-broke on macOS 14+)
// Built by install.sh with swiftc (present wherever Homebrew is).
import AppKit

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "cursor":
    if let e = CGEvent(source: nil) {
        print("\(Int(e.location.x)),\(Int(e.location.y))")
    } else {
        exit(1)
    }
case "wallpaper":
    guard args.count > 2 else { exit(1) }
    let url = URL(fileURLWithPath: args[2])
    var failures = 0
    for screen in NSScreen.screens {
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            failures += 1
            FileHandle.standardError.write("wallpaper: \(screen.localizedName): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
    exit(failures == 0 ? 0 : 1)
default:
    FileHandle.standardError.write("usage: omacosy-helper cursor | wallpaper <path>\n".data(using: .utf8)!)
    exit(1)
}
