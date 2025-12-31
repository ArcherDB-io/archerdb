#!/usr/bin/env bash
set -euo pipefail

# Run from repo root: ./zig/download.sh

ZIG_RELEASE="0.15.2"
ZIG_MIRROR="https://ziglang.org/download"

# Platform detection
ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) ZIG_ARCH="aarch64" ;;
    x86_64|amd64)  ZIG_ARCH="x86_64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

OS=$(uname -s)
case "$OS" in
    Linux)                 ZIG_OS="linux" ;;
    Darwin)                ZIG_OS="macos" ;;
    CYGWIN*|MINGW*|MSYS*)  ZIG_OS="windows" ;;
    *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

ZIG_TARGET="${ZIG_ARCH}-${ZIG_OS}"

# Checksums for Zig 0.15.2
case "$ZIG_TARGET" in
    x86_64-linux)   ZIG_CHECKSUM="02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239" ;;
    aarch64-linux)  ZIG_CHECKSUM="958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f" ;;
    x86_64-macos)   ZIG_CHECKSUM="375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f" ;;
    aarch64-macos)  ZIG_CHECKSUM="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b" ;;
    x86_64-windows) ZIG_CHECKSUM="3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c" ;;
    aarch64-windows) ZIG_CHECKSUM="b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370" ;;
    *) echo "No checksum for: $ZIG_TARGET"; exit 1 ;;
esac

if [ "$ZIG_OS" = "windows" ]; then
    ZIG_EXT="zip"
else
    ZIG_EXT="tar.xz"
fi

ZIG_DIRECTORY="zig-${ZIG_TARGET}-${ZIG_RELEASE}"
ZIG_ARCHIVE="${ZIG_DIRECTORY}.${ZIG_EXT}"
ZIG_URL="${ZIG_MIRROR}/${ZIG_RELEASE}/${ZIG_ARCHIVE}"

# Check if already installed
if [ -x "zig/zig" ]; then
    INSTALLED=$(zig/zig version 2>/dev/null || echo "")
    if [ "$INSTALLED" = "$ZIG_RELEASE" ]; then
        echo "Zig $ZIG_RELEASE already installed."
        exit 0
    fi
fi

echo "Downloading Zig $ZIG_RELEASE ($ZIG_TARGET)..."

# Download
if command -v curl >/dev/null 2>&1; then
    curl --progress-bar -L -o "$ZIG_ARCHIVE" "$ZIG_URL"
elif command -v wget >/dev/null 2>&1; then
    WGET_OPTS="--progress=bar:force"
    # Alpine Linux wget doesn't support -4
    [ ! -f /etc/alpine-release ] && WGET_OPTS="$WGET_OPTS -4"
    wget $WGET_OPTS -O "$ZIG_ARCHIVE" "$ZIG_URL" 2>&1
else
    echo "Error: curl or wget required"
    exit 1
fi

# Verify checksum
echo "Verifying checksum..."
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$ZIG_ARCHIVE" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$ZIG_ARCHIVE" | cut -d' ' -f1)
else
    echo "Warning: no sha256sum/shasum, skipping verification"
    ACTUAL="$ZIG_CHECKSUM"
fi

if [ "$ACTUAL" != "$ZIG_CHECKSUM" ]; then
    echo "Checksum mismatch!"
    echo "Expected: $ZIG_CHECKSUM"
    echo "Actual:   $ACTUAL"
    rm -f "$ZIG_ARCHIVE"
    exit 1
fi

# Extract
echo "Extracting..."
if [ "$ZIG_EXT" = "tar.xz" ]; then
    tar -xf "$ZIG_ARCHIVE"
else
    unzip -q "$ZIG_ARCHIVE"
fi

# Install to zig/
rm -rf zig/doc zig/lib zig/zig zig/LICENSE zig/README.md
mv "$ZIG_DIRECTORY/doc" zig/
mv "$ZIG_DIRECTORY/lib" zig/
mv "$ZIG_DIRECTORY/zig" zig/
mv "$ZIG_DIRECTORY/LICENSE" zig/
mv "$ZIG_DIRECTORY/README.md" zig/

# Cleanup
rm -rf "$ZIG_DIRECTORY" "$ZIG_ARCHIVE"

echo "Zig $ZIG_RELEASE installed to zig/zig"
