#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="AgentRadar"
BUILD_APP="${REPO_ROOT}/build/Build/Products/Release/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"

cd "${REPO_ROOT}"

xcodebuild -project AgentRadar.xcodeproj \
	-scheme AgentRadar \
	-configuration Release \
	-derivedDataPath build \
	build

osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true

for _ in {1..20}; do
	if ! pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
		break
	fi
	sleep 0.25
done

ditto "${BUILD_APP}" "${INSTALL_APP}"

for _ in {1..5}; do
	if open "${INSTALL_APP}"; then
		exit 0
	fi
	sleep 0.5
done

echo "Failed to relaunch ${APP_NAME}" >&2
exit 1
