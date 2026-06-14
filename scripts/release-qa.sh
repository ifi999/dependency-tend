#!/bin/bash
# Non-destructive release QA for DependencyTend.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DependencyTend.app"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dependency-tend-release-qa.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

step() {
  printf '\n==> %s\n' "$*"
}

step "Run full test suite"
swift test

step "Build release binary"
swift build -c release

step "Create app bundle"
./scripts/make-app.sh

step "Validate app bundle"
./scripts/validate-app-bundle.sh "$APP"

step "Dry-run staged install into temporary destination"
DEPENDENCY_TEND_SOURCE_APP="$APP" \
DEPENDENCY_TEND_DESTINATION_APP="$TEMP_ROOT/DependencyTend.app" \
DEPENDENCY_TEND_SKIP_BUILD=1 \
./scripts/install-app.sh --dry-run --no-launch

step "Check whitespace in tracked changes"
git diff --check

step "Show git status"
git status --short --branch

printf '\nRelease QA automated checks passed. Open build/DependencyTend.app and complete manual app checks before publishing.\n'
