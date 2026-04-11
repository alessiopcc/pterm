#!/bin/bash
set -e

PREFIX="${PREFIX:-/usr/local}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pterm"

echo "Installing PTerm..."

# Install binary
install -Dm755 pterm "$PREFIX/bin/pterm"

# Desktop entry
mkdir -p "$HOME/.local/share/applications"
if [ -f pterm.desktop ]; then
  cp pterm.desktop "$HOME/.local/share/applications/pterm.desktop"
fi

# Create config directory
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
  "$PREFIX/bin/pterm" --init-config || echo "Run 'pterm --init-config' to generate default config"
fi

echo "Installed to $PREFIX/bin/pterm"
echo "Config: $CONFIG_DIR/config.toml"
echo "Desktop entry: $HOME/.local/share/applications/pterm.desktop"
