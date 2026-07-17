#!/bin/bash
# Builds Ferri.app in Release mode and installs it into /Applications.
#
# Usage:
#   scripts/install.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/Applications"
APP_NAME="Ferri.app"

"${ROOT_DIR}/scripts/build.sh" Release

BUILT_APP="${ROOT_DIR}/build/${APP_NAME}"
TARGET_APP="${INSTALL_DIR}/${APP_NAME}"

if pgrep -x "Ferri" >/dev/null 2>&1; then
  echo "Quitting running Ferri instance..."
  osascript -e 'quit app "Ferri"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x "Ferri" >/dev/null 2>&1 || true
fi

echo "Installing ${APP_NAME} to ${INSTALL_DIR}..."
rm -rf "${TARGET_APP}"
cp -R "${BUILT_APP}" "${TARGET_APP}"

echo "Installed ${TARGET_APP}"
