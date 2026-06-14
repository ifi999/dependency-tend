#!/bin/bash
# Build and replace /Applications/DependencyTend.app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DependencyTend"
BUNDLE_ID="dev.ifi999.dependency-tend"
SOURCE_APP="${DEPENDENCY_TEND_SOURCE_APP:-build/DependencyTend.app}"
DESTINATION_APP="${DEPENDENCY_TEND_DESTINATION_APP:-/Applications/DependencyTend.app}"
DRY_RUN=0
LAUNCH_AFTER=1

usage() {
  cat <<USAGE
Usage: ./scripts/install-app.sh [--dry-run] [--no-launch]

Builds DependencyTend.app, replaces /Applications/DependencyTend.app, and relaunches it.

Environment:
  DEPENDENCY_TEND_DESTINATION_APP  Override destination for tests; basename must be DependencyTend.app.
  DEPENDENCY_TEND_SOURCE_APP       Override source bundle path; default build/DependencyTend.app.
  DEPENDENCY_TEND_SKIP_BUILD=1     Skip make-app.sh, useful for dry runs/tests.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-launch)
      LAUNCH_AFTER=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ "$(basename "$DESTINATION_APP")" != "$APP_NAME.app" ]]; then
  echo "Refusing to install outside a $APP_NAME.app destination: $DESTINATION_APP" >&2
  exit 64
fi

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

if [[ "${DEPENDENCY_TEND_SKIP_BUILD:-0}" != "1" ]]; then
  run ./scripts/make-app.sh
fi

if [[ "$DRY_RUN" -eq 0 || "${DEPENDENCY_TEND_SKIP_BUILD:-0}" == "1" ]]; then
  ./scripts/validate-app-bundle.sh "$SOURCE_APP"
fi

echo "Installing $APP_NAME:"
echo "  source:      $SOURCE_APP"
echo "  destination: $DESTINATION_APP"

DESTINATION_DIR="$(dirname "$DESTINATION_APP")"
STAGING_APP="$DESTINATION_APP.install-$$"
BACKUP_APP="$DESTINATION_APP.previous-$$"
INSTALL_SUCCEEDED=0

cleanup_install() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi
  if [[ "$INSTALL_SUCCEEDED" -ne 1 && -e "$BACKUP_APP" ]]; then
    rm -rf "$DESTINATION_APP"
    mv "$BACKUP_APP" "$DESTINATION_APP"
  fi
  rm -rf "$STAGING_APP" "$BACKUP_APP"
}
trap cleanup_install EXIT

if [[ "$DRY_RUN" -eq 0 ]]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
fi

run mkdir -p "$DESTINATION_DIR"
run rm -rf "$STAGING_APP" "$BACKUP_APP"
run cp -R "$SOURCE_APP" "$STAGING_APP"

if [[ "$DRY_RUN" -eq 0 ]]; then
  ./scripts/validate-app-bundle.sh "$STAGING_APP"
fi

if [[ -e "$DESTINATION_APP" ]]; then
  run mv "$DESTINATION_APP" "$BACKUP_APP"
fi
run mv "$STAGING_APP" "$DESTINATION_APP"

if [[ "${DEPENDENCY_TEND_ALLOW_TEST_HOOKS:-0}" == "1" && "${DEPENDENCY_TEND_FAIL_AFTER_REPLACE:-0}" == "1" ]]; then
  echo "Injected install failure after replacement" >&2
  exit 70
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  ./scripts/validate-app-bundle.sh "$DESTINATION_APP"
  INSTALL_SUCCEEDED=1
  if [[ -e "$BACKUP_APP" ]]; then
    run rm -rf "$BACKUP_APP"
  fi
fi

if [[ "$LAUNCH_AFTER" -eq 1 ]]; then
  run open "$DESTINATION_APP"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "✓ $APP_NAME dry run complete for $DESTINATION_APP"
else
  echo "✓ $APP_NAME installed at $DESTINATION_APP"
fi
