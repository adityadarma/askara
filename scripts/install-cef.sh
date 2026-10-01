#!/bin/zsh
# Installs the pinned official CEF macOS arm64 binary distribution into Vendor/cef.
set -euo pipefail
cd "${0:A:h}/.."

readonly CEF_VERSION="154.0.32+g682c378+chromium-154.0.8037.58"
readonly CEF_ARCHIVE="cef_binary_${CEF_VERSION}_macosarm64_minimal.tar.bz2"
readonly CEF_SHA1="2e9df1077c097e450d30f26804b7c4b1820da4e3"
readonly CEF_URL="https://cef-builds.spotifycdn.com/${CEF_ARCHIVE}"
readonly VENDOR_ROOT="Vendor/cef"
readonly DOWNLOAD_DIR="${TMPDIR:-/tmp}/askara-cef"
readonly ARCHIVE_PATH="$DOWNLOAD_DIR/$CEF_ARCHIVE"

if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "This pinned CEF distribution requires an arm64 Mac."
    exit 1
fi

if [[ -f "$VENDOR_ROOT/.version" ]] && [[ "$(<"$VENDOR_ROOT/.version")" == "$CEF_VERSION" ]]; then
    print "CEF $CEF_VERSION is already installed."
    exit 0
fi

mkdir -p "$DOWNLOAD_DIR" Vendor
if [[ ! -f "$ARCHIVE_PATH" ]]; then
    curl --fail --location --progress-bar "$CEF_URL" --output "$ARCHIVE_PATH"
fi

actual_sha1="$(shasum -a 1 "$ARCHIVE_PATH" | cut -d ' ' -f 1)"
if [[ "$actual_sha1" != "$CEF_SHA1" ]]; then
    print -u2 "CEF checksum mismatch: expected $CEF_SHA1, got $actual_sha1"
    exit 1
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/askara-cef-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
tar -xjf "$ARCHIVE_PATH" -C "$staging"
extracted=("$staging"/cef_binary_*_macosarm64_minimal)
if (( ${#extracted} != 1 )); then
    print -u2 "Unexpected CEF archive layout."
    exit 1
fi

rm -rf "$VENDOR_ROOT"
mv "$extracted[1]" "$VENDOR_ROOT"
print -r -- "$CEF_VERSION" > "$VENDOR_ROOT/.version"

# Build the official C++ wrapper required by CEF's C++ API and macOS library loader.
cmake -S "$VENDOR_ROOT" -B "$VENDOR_ROOT/build" \
    -G Xcode \
    -DPROJECT_ARCH=arm64 \
    -DUSE_SANDBOX=OFF
cmake --build "$VENDOR_ROOT/build" --config Release --target libcef_dll_wrapper

print "Installed CEF $CEF_VERSION in $VENDOR_ROOT"
