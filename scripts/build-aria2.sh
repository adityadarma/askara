#!/bin/zsh
# Builds a self-contained aria2c (BitTorrent engine for torrent downloads) into build/aria2/aria2c.
# Uses Apple's TLS stack, so the binary links only against system libraries.
#   --universal  build arm64 + x86_64 and merge them with lipo (default: native architecture only)
# aria2 is GPL-2.0-or-later. It runs as a separate executable and is not linked into Askara.
set -euo pipefail
cd "${0:A:h}/.."

SUMS="scripts/aria2-checksums.txt"
OUT="build/aria2"

ARCHS=("$(uname -m)")
[[ "${1:-}" == "--universal" ]] && ARCHS=(arm64 x86_64)

# Newest upstream release. Offline or rate limited: reuse the binary built earlier, if any.
VERSION="$(curl -fsSL --max-time 15 https://api.github.com/repos/aria2/aria2/releases/latest 2>/dev/null \
    | sed -n 's/.*"tag_name": *"release-\([0-9][0-9.]*\)".*/\1/p' | head -1 || true)"
if [[ -z "$VERSION" ]]; then
    if [[ -x "$OUT/aria2c" ]]; then
        print -u2 "Could not look up the latest aria2 release; reusing the existing build."
        exit 0
    fi
    print -u2 "Could not look up the latest aria2 release and there is no earlier build."
    exit 1
fi

# The cache key covers version and architectures, so a new release or architecture rebuilds.
STAMP="$VERSION-${(j:+:)ARCHS}"
if [[ -x "$OUT/aria2c" && "$(cat "$OUT/stamp" 2>/dev/null)" == "$STAMP" ]]; then
    exit 0
fi

mkdir -p "$OUT"
TARBALL="$OUT/aria2-$VERSION.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
    curl -fsSL -o "$TARBALL" "https://github.com/aria2/aria2/releases/download/release-$VERSION/aria2-$VERSION.tar.xz"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
EXPECTED="$(awk -v v="$VERSION" '$1 == v { print $2 }' "$SUMS")"
if [[ -n "$EXPECTED" ]]; then
    if [[ "$ACTUAL" != "$EXPECTED" ]]; then
        rm -f "$TARBALL"
        print -u2 "aria2 $VERSION checksum does not match $SUMS. The download was changed after it was first recorded."
        exit 1
    fi
elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    # Releases are signed with the app's certificate, so CI only ships sources someone has reviewed.
    print -u2 "aria2 $VERSION is new. Build it locally once, review it, and commit $SUMS."
    exit 1
else
    echo "$VERSION $ACTUAL" >> "$SUMS"
    print -u2 "NEW aria2 release $VERSION: recorded SHA-256 $ACTUAL in $SUMS. Commit it after reviewing the release."
fi

SRC="$OUT/src"
rm -rf "$SRC" && mkdir -p "$SRC"
tar -xf "$TARBALL" -C "$SRC" --strip-components=1

BINARIES=()
for arch in "${ARCHS[@]}"; do
    BUILD="$OUT/build-$arch"
    rm -rf "$BUILD" && mkdir -p "$BUILD"
    host="$arch-apple-darwin"
    [[ "$arch" == "arm64" ]] && host="aarch64-apple-darwin"
    (
        cd "$BUILD"
        "../src/configure" --host="$host" --disable-shared --enable-static --disable-nls \
            --disable-metalink --disable-websocket \
            --without-libxml2 --without-libexpat --without-openssl --without-gnutls \
            --without-libgcrypt --without-libnettle --without-sqlite3 --without-libssh2 \
            --without-libcares --without-libuv --without-jemalloc --without-tcmalloc \
            --with-appletls \
            CC="clang -arch $arch -mmacosx-version-min=14.0" \
            CXX="clang++ -arch $arch -mmacosx-version-min=14.0 -std=c++11" >configure.log 2>&1
        make -j"$(sysctl -n hw.ncpu)" -C src aria2c >make.log 2>&1
    ) || { print -u2 "aria2 build failed for $arch; see $BUILD/*.log"; exit 1; }
    BINARIES+=("$BUILD/src/aria2c")
done

lipo -create "${BINARIES[@]}" -output "$OUT/aria2c"
strip -x "$OUT/aria2c"
cp "$SRC/COPYING" "$OUT/COPYING"
echo "$STAMP" > "$OUT/stamp"
echo "Built aria2c $VERSION (${ARCHS[*]})."
