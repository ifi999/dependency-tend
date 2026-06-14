#!/bin/bash
# Validate the DependencyTend .app bundle shape without launching it.
set -euo pipefail

APP="${1:-build/DependencyTend.app}"
INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/DependencyTend"

fail() {
  echo "✗ $*" >&2
  exit 1
}

[[ -d "$APP" ]] || fail "app bundle not found: $APP"
[[ -f "$INFO" ]] || fail "Info.plist not found: $INFO"
[[ -f "$EXECUTABLE" ]] || fail "executable not found: $EXECUTABLE"
[[ -s "$EXECUTABLE" ]] || fail "executable is empty: $EXECUTABLE"
[[ -x "$EXECUTABLE" ]] || fail "executable is not executable: $EXECUTABLE"

if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null || true)"
  EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO" 2>/dev/null || true)"
  [[ "$IDENTIFIER" == "dev.ifi999.dependency-tend" ]] \
    || fail "unexpected CFBundleIdentifier: ${IDENTIFIER:-<missing>}"
  [[ "$EXECUTABLE_NAME" == "DependencyTend" ]] \
    || fail "unexpected CFBundleExecutable: ${EXECUTABLE_NAME:-<missing>}"
fi

echo "✓ $APP bundle looks valid"
