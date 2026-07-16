#!/bin/bash
# Builds Ferri.app from Ferri.xcworkspace and copies it into ./build.
#
# Usage:
#   scripts/build.sh [Debug|Release]
#
# The built .app is left at ./build/Ferri.app

set -euo pipefail

CONFIGURATION="${1:-Release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"

cd "${ROOT_DIR}"

echo "Building Ferri.app (${CONFIGURATION})..."

xcodebuild \
  -workspace Ferri.xcworkspace \
  -scheme Ferri \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  build

APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}/Ferri.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "error: expected build output not found at ${APP_PATH}" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}/Ferri.app"
cp -R "${APP_PATH}" "${BUILD_DIR}/Ferri.app"

echo "Built ${BUILD_DIR}/Ferri.app"
