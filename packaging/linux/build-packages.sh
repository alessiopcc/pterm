#!/bin/bash
set -e

VERSION="${1:?Usage: build-packages.sh VERSION ARCH}"
ARCH="${2:-amd64}"

# Validate VERSION is a valid SemVer string to prevent shell injection
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]; then
  echo "Invalid version: $VERSION" >&2; exit 1
fi

# Validate ARCH is one of the expected values
if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
  echo "Invalid architecture: $ARCH (expected amd64 or arm64)" >&2; exit 1
fi

# Map arch for rpm
RPM_ARCH="$ARCH"
if [ "$ARCH" = "amd64" ]; then RPM_ARCH="x86_64"; fi
if [ "$ARCH" = "arm64" ]; then RPM_ARCH="aarch64"; fi

echo "Building packages for PTerm v${VERSION} (${ARCH})..."

# Build .deb
echo "Building .deb package..."
fpm -s dir -t deb \
  -n pterm -v "$VERSION" \
  --architecture "$ARCH" \
  --maintainer "PTerm Project" \
  --description "GPU-accelerated terminal emulator for the agentic code era" \
  --url "https://github.com/alessiopcc/pterm" \
  --license "MIT" \
  --depends "libx11-6" \
  --depends "libwayland-client0" \
  --depends "libgl1" \
  zig-out/bin/pterm=/usr/bin/pterm \
  packaging/linux/pterm.desktop=/usr/share/applications/pterm.desktop

echo ".deb package created."

# Build .rpm
echo "Building .rpm package..."
fpm -s dir -t rpm \
  -n pterm -v "$VERSION" \
  --architecture "$RPM_ARCH" \
  --maintainer "PTerm Project" \
  --description "GPU-accelerated terminal emulator for the agentic code era" \
  --url "https://github.com/alessiopcc/pterm" \
  --license "MIT" \
  --depends "libX11" \
  --depends "libwayland-client" \
  --depends "mesa-libGL" \
  zig-out/bin/pterm=/usr/bin/pterm \
  packaging/linux/pterm.desktop=/usr/share/applications/pterm.desktop

echo ".rpm package created."
echo "All packages built for v${VERSION} (${ARCH})."
