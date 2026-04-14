<p align="center">
  <img src="assets/logo-256.png" alt="PTerm logo" width="128">
</p>

<h1 align="center">PTerm</h1>

<p align="center">
  A GPU-accelerated terminal emulator with built-in multiplexing and agent awareness.
</p>

<p align="center">
  <a href="https://github.com/alessiopcc/pterm/actions/workflows/ci.yml"><img src="https://github.com/alessiopcc/pterm/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/alessiopcc/pterm/releases/latest"><img src="https://img.shields.io/github/v/release/alessiopcc/pterm" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
</p>

## About

PTerm is a terminal emulator written in [Zig](https://ziglang.org/), built for
developers who work with AI coding agents. It provides native tabs and splits,
named layout presets, and an agent monitor that detects when
tools like Claude Code are waiting for input.

### Features

- **GPU-accelerated rendering** -- OpenGL 3.3 with instanced drawing, dual
  glyph atlases (grayscale text + color emoji), and procedural box-drawing
  shaders.
- **Tabs and splits** -- Create, close, resize, swap, zoom, and navigate panes
  with keyboard shortcuts. No external multiplexer needed.
- **Layout presets** -- Define named multi-tab, multi-pane layouts in your config
  and load them with a picker or `--layout <name>`.
- **Agent monitoring** -- Scans terminal output for prompt patterns from Claude
  Code, Copilot CLI, Aider, and others. Sends desktop notifications when an
  agent is waiting. Configurable presets (`conservative` / `broad`) and custom
  patterns.
- **HarfBuzz text shaping** -- Ligatures, kerning, and font fallback chains.
  FreeType on Linux/Windows, CoreText on macOS.
- **8 built-in color themes** -- default, dracula, solarized-dark,
  solarized-light, gruvbox-dark, nord, catppuccin-mocha, one-dark. Switch with
  a single config line.
- **Scrollback search** -- `Ctrl+Shift+F` to search buffer text with match
  counter and navigation.
- **URL detection** -- Hover-highlight clickable URLs, open with your OS handler.
- **Config hot-reload** -- Edit your config file and changes apply immediately.
- **Customizable keybindings** -- Remap any action in TOML or use the built-in
  interactive keybinding editor (`--set-keybindings`).
- **Cross-platform** -- Windows (ConPTY), macOS (CoreText), Linux (fontconfig,
  X11/Wayland).

## Installation

### Pre-built binaries

Download from the [latest release](https://github.com/alessiopcc/pterm/releases/latest):

| Platform | Package |
|----------|---------|
| Windows 10+ (1903) | `.msi` installer |
| macOS 12+ | `.dmg` |
| Debian/Ubuntu | `.deb` |
| Fedora/RHEL | `.rpm` |
| Linux (portable) | `.tar.gz` |

> **Note:** PTerm is not code-signed. On **macOS**, right-click the app and
> select "Open" on first launch, or run `xattr -cr /Applications/PTerm.app`.
> On **Windows**, click "More info" then "Run anyway" if SmartScreen appears.

### Build from source

Requires [Zig 0.15.2](https://ziglang.org/download/):

```sh
zig build --release=safe
```

Binary output: `zig-out/bin/pterm`

## Configuration

PTerm uses [TOML](https://toml.io/) for configuration. Generate a default config:

```sh
pterm --init-config
```

Config location on all platforms: `~/.config/pterm/config.toml`
(`%USERPROFILE%\.config\pterm\config.toml` on Windows).

Configuration is loaded in layers -- each layer overrides the previous:

1. Built-in defaults
2. Config file
3. `PTERM_*` environment variables
4. CLI flags

### Example config

```toml
theme = "dracula"

[font]
family = "JetBrains Mono"
size = 14.0

[window]
cols = 120
rows = 40
opacity = 0.95

[cursor]
style = "bar"       # block, bar, underline
blink = true

[scrollback]
lines = 50000

[shell]
program = "/bin/zsh"
args = ["--login"]

[bell]
mode = "none"       # visual, sound, both, none

[agent]
enabled = true
preset = "broad"    # conservative, broad
notifications = true
suppress_when_focused = true
custom_patterns = ["my-custom-tool>"]

[url]
enabled = true

[status_bar]
visible = true
```

You can also import shared base configs:

```toml
import = ["base.toml"]
theme = "nord"
```

### Themes

Set the `theme` key at the top level. Available built-in themes:

`default` `dracula` `solarized-dark` `solarized-light` `gruvbox-dark` `nord` `catppuccin-mocha` `one-dark`

Individual colors can be overridden under `[colors]`, `[colors.normal]`,
`[colors.bright]`, and `[colors.ui]` -- overrides take precedence over the
active theme.

### Keybindings

All actions are rebindable. Set them under `[keybindings]` in your config:

```toml
[keybindings]
split_horizontal = "ctrl+d"
split_vertical = "ctrl+shift+d"
new_tab = "ctrl+t"
```

Set an action to `"none"` to unbind it. Clipboard keys (`Ctrl+C`/`Ctrl+V`) are
reserved and cannot be overridden.

<details>
<summary>Default keybindings</summary>

| Action | Shortcut |
|--------|----------|
| New tab | `Ctrl+Shift+T` |
| Close tab | `Ctrl+Shift+W` |
| Next tab | `Ctrl+Tab` |
| Previous tab | `Ctrl+Shift+Tab` |
| Go to tab 1-9 | `Alt+1` ... `Alt+9` |
| Go to last tab | `Alt+0` |
| Move tab left/right | `Ctrl+Shift+PageUp/PageDown` |
| Split horizontal | `Ctrl+Shift+H` |
| Split vertical | `Ctrl+Shift+V` |
| Close pane | `Ctrl+Shift+X` |
| Focus pane (direction) | `Ctrl+Shift+Arrow` |
| Resize pane (direction) | `Ctrl+Alt+Arrow` |
| Swap pane (direction) | `Ctrl+Alt+Shift+Arrow` |
| Zoom pane | `Ctrl+Shift+Z` |
| Equalize panes | `Ctrl+Shift+E` |
| Rotate split | `Ctrl+Shift+R` |
| Break out pane | `Ctrl+Shift+B` |
| Search | `Ctrl+Shift+F` |
| Scroll page up/down | `Shift+PageUp/PageDown` |
| Scroll to top/bottom | `Ctrl+Shift+Home/End` |
| Layout picker | `Ctrl+Shift+L` |
| Toggle agent tab | `Ctrl+Shift+A` |
| Change shell | `Ctrl+Shift+S` |
| Font size +/−/reset | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` |
| Copy / Paste | `Ctrl+C` / `Ctrl+V` |

</details>

## Layout Presets

Define named layouts under `[layout.<name>]` in your config. Each layout can
have multiple tabs, each with multiple panes arranged via splits:

```toml
[layout.dev]

[[layout.dev.tab]]

[[layout.dev.tab.pane]]
dir = "~/project"
cmd = "nvim"

[[layout.dev.tab.pane]]
dir = "~/project"
split = "right"
ratio = 0.4

[[layout.dev.tab]]

[[layout.dev.tab.pane]]
dir = "~/project"
cmd = "npm run dev"

[[layout.dev.tab.pane]]
dir = "~/project"
cmd = "npm test -- --watch"
split = "down"
ratio = 0.5
```

Load a layout at startup:

```sh
pterm --layout dev
```

Or press `Ctrl+Shift+L` at any time to open the layout picker.

Each pane supports:

| Field | Description |
|-------|-------------|
| `dir` | Working directory (`~` expanded) |
| `cmd` | Startup command |
| `split` | `"right"` or `"down"` (omit for the first pane) |
| `ratio` | Split ratio, 0.0--1.0 (default 0.5) |
| `shell` | Per-pane shell override |
| `shell_args` | Shell arguments |

## CLI Reference

```
pterm [options]

  --config <path>       Config file path
  --layout <name>       Load a named layout preset
  --font-size <float>   Override font size
  --title <string>      Window title
  --cols <int>          Initial columns
  --rows <int>          Initial rows
  --working-dir <path>  Working directory

  --init-config         Generate default config file
  --dump-config         Print full default config
  --check-config        Validate config file
  --set-keybindings     Interactive keybinding editor

  --version             Print version
  --help                Show help
```

## Requirements

| Platform | Minimum | Notes |
|----------|---------|-------|
| Windows | 10 v1903+ | ConPTY pseudo-terminal support |
| macOS | 12 (Monterey) | CoreText font rendering |
| Linux | glibc 2.35+ | fontconfig, OpenGL 3.3, X11 or Wayland |

## License

PTerm is released under the [MIT License](LICENSE).
