#!/usr/bin/env bash
# Build a device iOS Release IPA for TrollStore (local / jailbroken install).
#
# Usage:
#   ./make-ipa.sh
#
# Optional env:
#   CONFIG=Release              # default Release
#   VERSION=0.2.0               # marketing version stamped into the app + IPA name
#   DEVELOPMENT_TEAM=XXXXXXXX   # if you have an Apple Development cert, use it
#   BUNDLE_ID=com.example.app   # override bundle id (recommended for local builds)
#
# Output: build/AmperfyPlus-<version>.ipa
#
# Install: copy the IPA to the iPad and open it with TrollStore.
# Without DEVELOPMENT_TEAM this builds unsigned (CODE_SIGNING_ALLOWED=NO) and
# fake-signs with ldid when available — suitable for TrollStore.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Amperfy"
PROJECT="${ROOT}/Amperfy.xcodeproj"
CONFIG="${CONFIG:-Release}"
VERSION="${VERSION:-0.2.0}"
APP_PRODUCT_NAME="AmperfyPlus"
BUILD_DIR="${ROOT}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData-ios"
IPA_PATH="${BUILD_DIR}/${APP_PRODUCT_NAME}-${VERSION}.ipa"
DESTINATION="generic/platform=iOS"
LOCAL_ENTITLEMENTS="${BUILD_DIR}/AmperfyPlus-ios-local.entitlements"
BUNDLE_ID="${BUNDLE_ID:-de.familie-zimba.amperfyplus.local}"

cd "$ROOT"
mkdir -p "$BUILD_DIR"

# TrollStore / sideload entitlements: omit CarPlay & Siri; no Mac sandbox keys.
cat > "$LOCAL_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>get-task-allow</key>
	<true/>
	<key>platform-application</key>
	<true/>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
	<key>com.apple.private.security.container-required</key>
	<false/>
</dict>
</plist>
EOF

SIGN_ARGS=(
  CODE_SIGN_ENTITLEMENTS="$LOCAL_ENTITLEMENTS"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION=1
  IPHONEOS_DEPLOYMENT_TARGET=16.0
  TARGETED_DEVICE_FAMILY=2
)

XCODEBUILD_EXTRA=()
USE_LDID=0
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "==> Signing with DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
  SIGN_ARGS+=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="Apple Development"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
  )
  XCODEBUILD_EXTRA+=(-allowProvisioningUpdates)
else
  echo "==> No DEVELOPMENT_TEAM — building unsigned for TrollStore (ldid if present)"
  # iOS 26 SDK rejects ad-hoc device signing; skip codesign and fake-sign later.
  SIGN_ARGS+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    DEVELOPMENT_TEAM=""
    CODE_SIGN_IDENTITY=""
  )
  USE_LDID=1
fi

echo "==> Building iOS device (${CONFIG}, version ${VERSION}, deployment 16.0)…"
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

PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/${CONFIG}-iphoneos"
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

echo "==> Found $(basename "$APP_SRC") (version ${VERSION})"

STAGE="${BUILD_DIR}/ipa-stage"
PAYLOAD="${STAGE}/Payload"
rm -rf "$STAGE" "$IPA_PATH"
mkdir -p "$PAYLOAD"
cp -R "$APP_SRC" "${PAYLOAD}/${APP_PRODUCT_NAME}.app"

# Keep CFBundleDisplayName as Amperfy+; rename bundle folder for the IPA only.
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_PRODUCT_NAME}" \
  "${PAYLOAD}/${APP_PRODUCT_NAME}.app/Info.plist" 2>/dev/null || true

if [[ "$USE_LDID" -eq 1 ]]; then
  APP_BIN="${PAYLOAD}/${APP_PRODUCT_NAME}.app/Amperfy"
  if [[ ! -f "$APP_BIN" ]]; then
    # Binary name follows PRODUCT_NAME of the target (Amperfy).
    APP_BIN="$(find "${PAYLOAD}/${APP_PRODUCT_NAME}.app" -maxdepth 1 -type f -perm -111 -print -quit || true)"
  fi
  if command -v ldid >/dev/null 2>&1; then
    echo "==> Fake-signing with ldid…"
    if [[ -n "${APP_BIN}" && -f "${APP_BIN}" ]]; then
      ldid -S"$LOCAL_ENTITLEMENTS" "$APP_BIN"
    fi
    # Also sign nested frameworks when present.
    while IFS= read -r -d '' fw; do
      bin="${fw}/$(basename "$fw" .framework)"
      [[ -f "$bin" ]] && ldid -S"$LOCAL_ENTITLEMENTS" "$bin" || true
    done < <(find "${PAYLOAD}/${APP_PRODUCT_NAME}.app" -name '*.framework' -print0 2>/dev/null || true)
  else
    echo "warning: ldid not found — IPA is unsigned. Install ldid (e.g. brew install ldid) for TrollStore."
  fi
fi

echo "==> Creating IPA…"
(
  cd "$STAGE"
  zip -qry "$IPA_PATH" Payload
)

rm -rf "$STAGE"

echo "Done: ${IPA_PATH}"
ls -lh "$IPA_PATH"
echo
echo "Install: copy the IPA to the iPad and open it with TrollStore."
echo "Bundle ID: ${BUNDLE_ID}"
