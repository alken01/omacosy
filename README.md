# omarchy-mac

An [omarchy](https://omarchy.org)-style setup for macOS: tiling window
management, a themed status bar, active-window borders, a unified theme
switcher, and the CLI stack — all bootstrapped from this one repo.

## Fresh Mac

```sh
git clone git@github.com:paulsp94/omarchy-mac.git ~/Documents/paul/repos/omarchy-mac
~/Documents/paul/repos/omarchy-mac/install.sh
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

## Keybindings (alt = mod)

| Chord | Action |
|---|---|
| `alt+enter` | new Korren window |
| `alt+h/j/k/l` | focus window |
| `alt+shift+h/j/k/l` | move window |
| `alt+1..9` | switch workspace |
| `alt+shift+1..9` | move window to workspace |
| `alt+tab` | previous workspace |
| `alt+f` | fullscreen |
| `alt+v` | toggle floating |
| `alt+slash` / `alt+comma` | tiles / accordion layout |
| `alt+shift+q` | close window |
| `alt+r` | resize mode (`h/j/k/l`, `-`/`=`, `esc`) |
| `alt+shift+;` | service mode (`esc` reload, `r` flatten, `⌫` close others) |
