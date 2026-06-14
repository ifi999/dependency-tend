#!/bin/bash
# dependency-tend를 .app 번들로 만든다 (개인용 — ad-hoc 서명, 공증 없음)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DependencyTend"
VERSION_FILE="${DEPENDENCY_TEND_VERSION_FILE:-VERSION}"
APP="${DEPENDENCY_TEND_APP_OUTPUT:-build/$APP_NAME.app}"
RELEASE_BINARY="${DEPENDENCY_TEND_RELEASE_BINARY:-.build/release/$APP_NAME}"
BUILD_NUMBER="${DEPENDENCY_TEND_BUILD_NUMBER:-1}"
APP_UPDATE_PUBLIC_KEY="${DEPENDENCY_TEND_APP_UPDATE_PUBLIC_KEY:-}"

fail() {
  echo "✗ $*" >&2
  exit 1
}

[[ -f "$VERSION_FILE" ]] || fail "VERSION file not found: $VERSION_FILE"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION must be MAJOR.MINOR.PATCH: ${VERSION:-<empty>}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] \
  || fail "DEPENDENCY_TEND_BUILD_NUMBER must be numeric: $BUILD_NUMBER"

if [[ "${DEPENDENCY_TEND_SKIP_BUILD:-0}" != "1" ]]; then
  swift build -c release
fi

[[ -f "$RELEASE_BINARY" ]] || fail "release binary not found: $RELEASE_BINARY"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/scripts"
swift scripts/render-app-icon.swift "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.ifi999.dependency-tend</string>
    <key>CFBundleName</key>
    <string>DependencyTend</string>
    <key>CFBundleExecutable</key>
    <string>DependencyTend</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cp "$RELEASE_BINARY" "$APP/Contents/MacOS/"
cp scripts/install-app.sh scripts/validate-app-bundle.sh "$APP/Contents/Resources/scripts/"
chmod 755 "$APP/Contents/Resources/scripts/install-app.sh" \
          "$APP/Contents/Resources/scripts/validate-app-bundle.sh"
if [[ -n "$APP_UPDATE_PUBLIC_KEY" ]]; then
  [[ -f "$APP_UPDATE_PUBLIC_KEY" ]] || fail "app update public key not found: $APP_UPDATE_PUBLIC_KEY"
  cp "$APP_UPDATE_PUBLIC_KEY" "$APP/Contents/Resources/DependencyTendAppUpdatePublicKey.pem"
fi
if [[ "${DEPENDENCY_TEND_SKIP_CODESIGN:-0}" != "1" ]]; then
  codesign --force --sign - "$APP"
fi
./scripts/validate-app-bundle.sh "$APP"
echo "✅ $APP 생성 완료. 실행: open $APP"
echo "   영구 설치/갱신: ./scripts/install-app.sh"
