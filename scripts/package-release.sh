#!/bin/bash
# Build and verify release artifacts for DependencyTend app updates.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DependencyTend"
VERSION_FILE="${DEPENDENCY_TEND_VERSION_FILE:-VERSION}"
APP="${DEPENDENCY_TEND_RELEASE_APP:-build/$APP_NAME.app}"
OUTPUT_DIR="${DEPENDENCY_TEND_RELEASE_OUTPUT_DIR:-build/release-artifacts}"
BUILD_NUMBER="${DEPENDENCY_TEND_BUILD_NUMBER:-1}"
MINIMUM_APP_VERSION="${DEPENDENCY_TEND_MINIMUM_APP_VERSION:-1.0.0}"
SIGNING_KEY="${DEPENDENCY_TEND_MANIFEST_SIGNING_KEY:-}"
VERIFY_KEY="${DEPENDENCY_TEND_MANIFEST_VERIFY_KEY:-}"
ZIP_NAME="$APP_NAME.app.zip"
SHA_NAME="$ZIP_NAME.sha256"
MANIFEST_NAME="$APP_NAME.update-manifest.json"
SIGNATURE_NAME="$MANIFEST_NAME.sig"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
SHA_PATH="$OUTPUT_DIR/$SHA_NAME"
MANIFEST_PATH="$OUTPUT_DIR/$MANIFEST_NAME"
SIGNATURE_PATH="$OUTPUT_DIR/$SIGNATURE_NAME"
TEMP_VERIFY_KEY=""

fail() {
  echo "✗ $*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

cleanup() {
  if [[ -n "$TEMP_VERIFY_KEY" ]]; then
    rm -f "$TEMP_VERIFY_KEY"
  fi
}
trap cleanup EXIT

need_command git
need_command ditto
need_command zipinfo
need_command shasum
need_command openssl
need_command /usr/libexec/PlistBuddy

[[ -f "$VERSION_FILE" ]] || fail "VERSION file not found: $VERSION_FILE"
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION must be MAJOR.MINOR.PATCH: ${VERSION:-<empty>}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] \
  || fail "DEPENDENCY_TEND_BUILD_NUMBER must be numeric: $BUILD_NUMBER"
[[ "$MINIMUM_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "DEPENDENCY_TEND_MINIMUM_APP_VERSION must be MAJOR.MINOR.PATCH: $MINIMUM_APP_VERSION"

EXPECTED_TAG="v$VERSION"
if [[ "${DEPENDENCY_TEND_ALLOW_DIRTY:-0}" != "1" ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean for release packaging"
fi
if [[ "${DEPENDENCY_TEND_SKIP_TAG_CHECK:-0}" != "1" ]]; then
  CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
  [[ "$CURRENT_TAG" == "$EXPECTED_TAG" ]] \
    || fail "current tag must be $EXPECTED_TAG, got ${CURRENT_TAG:-<none>}"
fi

COMMIT_SHA="${DEPENDENCY_TEND_COMMIT_SHA:-$(git rev-parse HEAD)}"
[[ "$COMMIT_SHA" =~ ^[a-fA-F0-9]{40}$ ]] \
  || fail "commit SHA must be 40 hex characters: $COMMIT_SHA"

if [[ "${DEPENDENCY_TEND_SKIP_BUILD:-0}" != "1" ]]; then
  DEPENDENCY_TEND_APP_OUTPUT="$APP" \
    DEPENDENCY_TEND_BUILD_NUMBER="$BUILD_NUMBER" \
    ./scripts/make-app.sh
fi

./scripts/validate-app-bundle.sh "$APP"
INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] \
  || fail "bundle short version $BUNDLE_VERSION does not match VERSION $VERSION"
[[ "$BUNDLE_BUILD" == "$BUILD_NUMBER" ]] \
  || fail "bundle build $BUNDLE_BUILD does not match manifest buildNumber $BUILD_NUMBER"

if [[ "${DEPENDENCY_TEND_SKIP_ARCH_CHECK:-0}" != "1" ]]; then
  ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
  [[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] \
    || fail "release executable must be universal arm64+x86_64, got: ${ARCHS:-<unknown>}"
fi

verify_zip_root() {
  local zip_path="$1"
  local entries
  entries="$(zipinfo -1 "$zip_path")" || fail "cannot inspect release zip: $zip_path"
  [[ -n "$entries" ]] || fail "release zip is empty: $zip_path"
  while IFS= read -r entry; do
    [[ "$entry" != /* ]] || fail "zip entry uses absolute path: $entry"
    [[ "$entry" != *"../"* && "$entry" != *"/.."* ]] || fail "zip entry uses traversal: $entry"
    [[ "$entry" == "$APP_NAME.app/" || "$entry" == "$APP_NAME.app/"* ]] \
      || fail "zip root must be exactly $APP_NAME.app, got: $entry"
  done <<< "$entries"
}

mkdir -p "$OUTPUT_DIR"
rm -f "$ZIP_PATH" "$SHA_PATH" "$MANIFEST_PATH" "$SIGNATURE_PATH"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP_PATH"
verify_zip_root "$ZIP_PATH"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$ZIP_NAME" > "$SHA_NAME"
  shasum -a 256 -c "$SHA_NAME" >/dev/null
)
ASSET_SHA256="$(awk '{print $1}' "$SHA_PATH")"
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat > "$MANIFEST_PATH" <<JSON
{
  "version": "$VERSION",
  "tag": "$EXPECTED_TAG",
  "commitSHA": "$COMMIT_SHA",
  "buildNumber": "$BUILD_NUMBER",
  "minimumAppVersion": "$MINIMUM_APP_VERSION",
  "assetName": "$ZIP_NAME",
  "assetSHA256": "$ASSET_SHA256",
  "createdAt": "$CREATED_AT",
  "signatureFormat": "openssl-rsa-sha256"
}
JSON

[[ -n "$SIGNING_KEY" ]] || fail "DEPENDENCY_TEND_MANIFEST_SIGNING_KEY is required"
[[ -f "$SIGNING_KEY" ]] || fail "manifest signing key not found: $SIGNING_KEY"
openssl dgst -sha256 -sign "$SIGNING_KEY" -out "$SIGNATURE_PATH" "$MANIFEST_PATH"

if [[ -z "$VERIFY_KEY" ]]; then
  TEMP_VERIFY_KEY="$(mktemp "${TMPDIR:-/tmp}/dependency-tend-public-key.XXXXXX")"
  openssl pkey -in "$SIGNING_KEY" -pubout -out "$TEMP_VERIFY_KEY" >/dev/null 2>&1
  VERIFY_KEY="$TEMP_VERIFY_KEY"
fi
openssl dgst -sha256 -verify "$VERIFY_KEY" -signature "$SIGNATURE_PATH" "$MANIFEST_PATH" >/dev/null

echo "✓ Release artifacts written to $OUTPUT_DIR"
echo "  $ZIP_NAME"
echo "  $SHA_NAME"
echo "  $MANIFEST_NAME"
echo "  $SIGNATURE_NAME"
