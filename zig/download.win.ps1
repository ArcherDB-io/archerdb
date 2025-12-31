$ErrorActionPreference = "Stop"

# Run from repo root: ./zig/download.ps1

$ZIG_RELEASE = "0.15.2"
$ZIG_MIRROR = "https://ziglang.org/download"

# Architecture detection
$ZIG_ARCH = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    "aarch64"
} elseif ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
    "x86_64"
} else {
    Write-Error "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
    exit 1
}

$ZIG_TARGET = "$ZIG_ARCH-windows"

# Checksums for Zig 0.15.2
$ZIG_CHECKSUMS = @{
    "x86_64-windows" = "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c"
    "aarch64-windows" = "b926465f8872bf983422257cd9ec248bb2b270996fbe8d57872cca13b56fc370"
}

$ZIG_CHECKSUM = $ZIG_CHECKSUMS[$ZIG_TARGET]
if (-not $ZIG_CHECKSUM) {
    Write-Error "No checksum for: $ZIG_TARGET"
    exit 1
}

$ZIG_DIRECTORY = "zig-$ZIG_TARGET-$ZIG_RELEASE"
$ZIG_ARCHIVE = "$ZIG_DIRECTORY.zip"
$ZIG_URL = "$ZIG_MIRROR/$ZIG_RELEASE/$ZIG_ARCHIVE"

# Check if already installed
if (Test-Path "zig/zig.exe") {
    $INSTALLED = & zig/zig.exe version 2>$null
    if ($INSTALLED -eq $ZIG_RELEASE) {
        Write-Host "Zig $ZIG_RELEASE already installed."
        exit 0
    }
}

Write-Host "Downloading Zig $ZIG_RELEASE ($ZIG_TARGET)..."

# Download
Invoke-WebRequest -Uri $ZIG_URL -OutFile $ZIG_ARCHIVE

# Verify checksum
Write-Host "Verifying checksum..."
$ACTUAL = (Get-FileHash -Algorithm SHA256 $ZIG_ARCHIVE).Hash.ToLower()
if ($ACTUAL -ne $ZIG_CHECKSUM) {
    Write-Error "Checksum mismatch!"
    Write-Host "Expected: $ZIG_CHECKSUM"
    Write-Host "Actual:   $ACTUAL"
    Remove-Item $ZIG_ARCHIVE -Force
    exit 1
}

# Extract
Write-Host "Extracting..."
Expand-Archive -Path $ZIG_ARCHIVE -DestinationPath . -Force

# Install to zig/
Remove-Item -Path "zig/doc", "zig/lib", "zig/zig.exe", "zig/LICENSE", "zig/README.md" -Recurse -Force -ErrorAction SilentlyContinue
Move-Item "$ZIG_DIRECTORY/doc" "zig/"
Move-Item "$ZIG_DIRECTORY/lib" "zig/"
Move-Item "$ZIG_DIRECTORY/zig.exe" "zig/"
Move-Item "$ZIG_DIRECTORY/LICENSE" "zig/"
Move-Item "$ZIG_DIRECTORY/README.md" "zig/"

# Cleanup
Remove-Item $ZIG_DIRECTORY -Recurse -Force
Remove-Item $ZIG_ARCHIVE -Force

Write-Host "Zig $ZIG_RELEASE installed to zig/zig.exe"
