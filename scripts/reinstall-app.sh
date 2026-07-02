#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="AgentRadar"
BUILD_APP="${REPO_ROOT}/build/Build/Products/Release/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"

cd "${REPO_ROOT}"

swift test

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

RELAUNCH_MARKER="$(mktemp)"
trap 'rm -f "${RELAUNCH_MARKER}"' EXIT

launched=0
for _ in {1..5}; do
	if open "${INSTALL_APP}"; then
		launched=1
		break
	fi
	sleep 0.5
done

if [[ "${launched}" -ne 1 ]]; then
	echo "Failed to relaunch ${APP_NAME}" >&2
	exit 1
fi

# Smoke check: the app must stay alive and resume writing status decisions.
STATUS_LOG="${HOME}/Library/Logs/AgentRadar/status.log"
sleep 8

if ! pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
	echo "Smoke check failed: ${APP_NAME} is not running after relaunch" >&2
	exit 1
fi

# Status decisions are only logged when sessions exist, so a stale log is a
# warning rather than a failure.
if [[ -f "${STATUS_LOG}" && "${STATUS_LOG}" -nt "${RELAUNCH_MARKER}" ]]; then
	echo "Smoke check passed: ${APP_NAME} is running and scanning"
else
	echo "Smoke check: ${APP_NAME} is running; no fresh status.log entries yet (fine if no agent sessions are open)"
fi
