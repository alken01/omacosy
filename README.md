# omacosy

An [omarchy](https://omarchy.org)-style setup for macOS: tiling window
management, a themed status bar, active-window borders, a unified theme
switcher, and the CLI stack — all bootstrapped from this one repo.

## Fresh Mac

```sh
git clone git@github.com:paulsp94/omacosy.git ~/Documents/paul/repos/omacosy
~/Documents/paul/repos/omacosy/install.sh
```

The installer is idempotent — re-run it after pulling changes. It installs
Homebrew if missing, runs `brew bundle`, symlinks configs (backing up
anything it would replace), applies the default theme, and starts services.

One-time manual steps on a new machine:

1. Grant AeroSpace accessibility permission
   (System Settings → Privacy & Security → Accessibility).
2. Build Korren from its repo: `./packaging/macos/build-app.sh --install`.

## What's inside

| Piece | Tool | Config |
|---|---|---|
| Tiling WM | [AeroSpace](https://github.com/nikitabobko/AeroSpace) | `config/aerospace/aerospace.toml` |
| Status bar | [sketchybar](https://github.com/FelixKratz/SketchyBar) | `config/sketchybar/` |
| Window borders | [JankyBorders](https://github.com/FelixKratz/JankyBorders) | `config/borders/bordersrc` |
| Terminal | [Korren](https://github.com/paulsp94/korren) (built from source) | follows the theme switcher |
| Prompt | starship | `config/starship.toml` |
| Shell | zsh + oh-my-zsh | `zsh/zshrc` |
| CLI stack | fzf, eza, zoxide, ripgrep, bat, lazygit, btop | wired in `zsh/zshrc` |

## Themes

`theme-set <name>` switches everything at once — Korren, sketchybar, and
borders. It swaps the `~/.config/omarchy/current/theme` symlink (the same
convention omarchy uses on Linux); Korren watches that directory and
repaints live, sketchybar reloads, borders restyles in place.

```sh
theme-set              # list themes
theme-set catppuccin   # switch
```

Themes live in `themes/<name>/`:

- `colors.toml` — the 22-variable omarchy palette (read by Korren)
- `sketchybar.sh` — bar colors
- `borders.sh` — border colors

To add a theme, copy an existing directory and adjust the colors.

## Keybindings — Super = hold Caps Lock

Karabiner remaps Caps Lock to `cmd+ctrl+alt` (a combo macOS never uses),
so the omarchy scheme works letter-for-letter without breaking typing or
app shortcuts. Caps Lock tapped alone is Escape.

| Chord | Action |
|---|---|
| `Super+enter` | new Korren window |
| `Super+shift+enter` | browser (Arc) |
| `Super+space` | launcher (Raycast) |
| `Super+w` | close window |
| `Super+arrows` | focus window |
| `Super+shift+arrows` | move window |
| `Super+1..9` | switch workspace |
| `Super+shift+1..9` | move window to workspace |
| `Super+tab` | previous workspace |
| `Super+shift+tab` | throw workspace to other monitor |
| `Super+f` | fullscreen |
| `Super+t` | toggle floating |
| `Super+j` | toggle split direction |
| `Super+-` / `Super+=` | resize |
| `Super+shift+f/m/s` | Finder / Spotify / Slack |
| `Super+shift+t` | next theme |
| `Super+r` | resize mode (`h/j/k/l`, `-`/`=`, `esc`) |
| `Super+shift+;` | service mode (`esc` reload, `r` flatten, `⌫` close others) |

Workspaces 1–6 are pinned to the external display, 7–9 to the built-in
(each falls back to the main display when only one is connected).

## Back to a normal Mac

```sh
./uninstall.sh
```

Stops AeroSpace/sketchybar/borders/Karabiner, restores the native menu
bar and any backed-up configs, and relinks nothing. Homebrew packages
stay installed (removal command printed at the end).
