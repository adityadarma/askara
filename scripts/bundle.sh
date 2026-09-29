#!/bin/zsh
# Builds Hemat.app (release) in the build/ folder.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Hemat"
APP="build/Hemat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hemat"
# UI translations. English is the source language; macOS picks the lproj matching the user's language.
cp -R Localization/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Hemat</string>
    <key>CFBundleDisplayName</key><string>Hemat</string>
    <key>CFBundleIdentifier</key><string>local.hemat.browser</string>
    <key>CFBundleExecutable</key><string>Hemat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>id</string></array>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>LSMinimumSystemVersion</key><string>15.4</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Web</string>
            <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Passkeys need the com.apple.developer.web-browser.public-key-credential entitlement.
# Apple must approve it, and it is only valid with a Developer ID/Apple Development certificate
# plus a provisioning profile that includes it. Set these two variables to enable it:
#   HEMAT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   HEMAT_PROFILE=/path/to/Hemat.provisionprofile
# Without both, ad-hoc signing is used (passkeys unavailable).
if [[ -n "${HEMAT_SIGN_IDENTITY:-}" && -n "${HEMAT_PROFILE:-}" ]]; then
    cp "$HEMAT_PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENT="$(mktemp -t hemat-entitlements).plist"
    cat > "$ENT" <<'ENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.web-browser.public-key-credential</key><true/>
</dict>
</plist>
ENTPLIST
    codesign --force --options runtime --entitlements "$ENT" --sign "$HEMAT_SIGN_IDENTITY" "$APP"
    rm -f "$ENT"
    echo "Signed with passkey entitlement."
else
    codesign --force --sign - "$APP"
    echo "Ad-hoc signing: passkeys unavailable."
fi
echo "Done: $APP"
