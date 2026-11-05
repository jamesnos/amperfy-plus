#!/usr/bin/env bash
# Build a Mac Catalyst Release app and pack it into a DMG (local / personal use).
#
# Usage:
#   ./make-dmg.sh
#
# Optional env:
#   CONFIG=Release              # default Release
#   DEVELOPMENT_TEAM=XXXXXXXX   # if you have an Apple Development cert, use it
#   BUNDLE_ID=com.example.app   # override bundle id (recommended for local builds)
#
# Output: build/Amperfy.dmg
#
# Without an Apple Development certificate this uses ad-hoc signing. First launch
# may need right-click → Open (Gatekeeper). CarPlay/Siri entitlements are omitted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Amperfy"
PROJECT="${ROOT}/Amperfy.xcodeproj"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="${ROOT}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
DMG_PATH="${BUILD_DIR}/Amperfy.dmg"
VOL_NAME="Amperfy"
DESTINATION="platform=macOS,variant=Mac Catalyst"
LOCAL_ENTITLEMENTS="${BUILD_DIR}/Amperfy-local.entitlements"
BUNDLE_ID="${BUNDLE_ID:-de.familie-zimba.amperfy-music.local}"

cd "$ROOT"
mkdir -p "$BUILD_DIR"

# Personal / ad-hoc builds cannot use CarPlay or Siri capabilities.
cat > "$LOCAL_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF

SIGN_ARGS=(
  CODE_SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  ENABLE_HARDENED_RUNTIME=NO
)

XCODEBUILD_EXTRA=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "==> Signing with DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
  SIGN_ARGS+=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="Apple Development"
  )
  XCODEBUILD_EXTRA+=(-allowProvisioningUpdates)
else
  echo "==> No DEVELOPMENT_TEAM set — using ad-hoc signing (local use only)"
  SIGN_ARGS+=(
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    DEVELOPMENT_TEAM=""
    CODE_SIGN_STYLE=Manual
  )
fi

echo "==> Building Mac Catalyst (${CONFIG})…"
rm -rf "$DERIVED_DATA"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  "${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"}" \
  "${SIGN_ARGS[@]}" \
  build

PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/${CONFIG}-maccatalyst"
APP_SRC=""
if [[ -d "${PRODUCTS_DIR}/Amperfy.app" ]]; then
  APP_SRC="${PRODUCTS_DIR}/Amperfy.app"
else
  APP_SRC="$(find "$PRODUCTS_DIR" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
fi

if [[ -z "${APP_SRC}" || ! -d "${APP_SRC}" ]]; then
  echo "error: could not find .app under ${PRODUCTS_DIR}" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_SRC")"
echo "==> Found ${APP_NAME}"

# Ensure deep ad-hoc signature when not using a real team.
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "==> Ad-hoc codesign…"
  codesign --force --deep --sign - \
    --entitlements "$LOCAL_ENTITLEMENTS" \
    "$APP_SRC"
fi

STAGE="${BUILD_DIR}/dmg-stage"
rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"
cp -R "$APP_SRC" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"

echo "==> Creating DMG…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGE"

echo "Done: ${DMG_PATH}"
ls -lh "$DMG_PATH"
echo
echo "Install: open the DMG and drag Amperfy to Applications."
echo "If macOS blocks launch: right-click the app → Open."
