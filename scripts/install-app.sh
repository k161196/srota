#!/bin/bash
# Build Srota and install the app bundle into /Applications.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/srota/srota.xcodeproj"
SCHEME="srota"
DERIVED_DATA_PATH="$ROOT_DIR/.build/install-app"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/srota.app"
INSTALL_PATH="/Applications/srota.app"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found: $PROJECT_PATH" >&2
  exit 1
fi

echo "Building $SCHEME..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "Built app not found: $BUILT_APP_PATH" >&2
  exit 1
fi

if [[ -e "$INSTALL_PATH" ]] && [[ ! -w "$INSTALL_PATH" ]]; then
  echo "Cannot replace $INSTALL_PATH. Re-run with sudo." >&2
  exit 1
fi

if [[ ! -w "/Applications" ]]; then
  echo "Cannot write to /Applications. Re-run with sudo." >&2
  exit 1
fi

echo "Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
/usr/bin/ditto "$BUILT_APP_PATH" "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH"
