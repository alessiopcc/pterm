# Release Checklist

Manual verification before publishing a GitHub Release draft.

## Prerequisites
- [ ] CI green on all 3 platforms
- [ ] All E2E tests passing
- [ ] Draft release created with all artifacts

## Visual Smoke Tests (per platform)

### All Platforms
- [ ] PTerm launches without errors
- [ ] `pterm --version` prints correct version
- [ ] `pterm --help` shows help text
- [ ] `pterm --init-config` creates config file
- [ ] Default shell spawns and accepts input
- [ ] Typing echo commands produces correct output
- [ ] Window resizes without rendering artifacts
- [ ] Font renders correctly (no garbled text)
- [ ] Color output works (run `ls --color` or equivalent)
- [ ] Emoji display correctly (test: echo "Hello World")
- [ ] Tab creation/close works (Ctrl+Shift+T / Ctrl+Shift+W)
- [ ] Pane splitting works (Ctrl+Shift+D horizontal, Ctrl+Shift+E vertical)
- [ ] Keyboard navigation between panes works
- [ ] Scrollback works (scroll up through output)
- [ ] Copy/paste works (Ctrl+C/V or Cmd+C/V)
- [ ] Agent detection triggers on known patterns (test: echo "? ")
- [ ] Status bar shows pane state

### Windows-Specific
- [ ] MSI installer completes without errors
- [ ] PTerm appears in Start Menu after install
- [ ] PTerm is in PATH after install (new terminal: `pterm --version`)
- [ ] PowerShell works as shell
- [ ] cmd.exe works as shell
- [ ] Uninstall removes PATH entry and Start Menu shortcut

### macOS-Specific
- [ ] .dmg mounts and shows drag-to-Applications
- [ ] Right-click > Open bypasses Gatekeeper (no code signing)
- [ ] .app launches from Applications folder
- [ ] zsh works as shell
- [ ] Metal rendering (check no OpenGL fallback warnings)

### Linux-Specific
- [ ] .deb installs via dpkg -i
- [ ] .rpm installs via rpm -i (on RPM-based system)
- [ ] tar.gz install.sh runs without errors
- [ ] .desktop file shows PTerm in application launcher
- [ ] X11 session works
- [ ] Wayland session works
- [ ] bash works as shell

## Final Steps
- [ ] CHANGELOG.md reviewed for accuracy
- [ ] SHA256SUMS.txt matches downloaded artifacts
- [ ] Publish release (convert from draft to published)
