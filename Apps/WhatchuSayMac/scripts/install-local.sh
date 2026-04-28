#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WhatchuSayMac"
DEST="/Applications/${APP_NAME}.app"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData"

SRC="$(find "${DERIVED}" -name "${APP_NAME}.app" \
        -path "*/Build/Products/Debug/*" \
        -not -path "*Index.noindex*" \
        -print0 2>/dev/null \
      | xargs -0 stat -f "%m %N" \
      | sort -rn \
      | head -1 \
      | cut -d' ' -f2-)"

if [[ -z "${SRC}" || ! -d "${SRC}" ]]; then
  echo "error: no Debug build of ${APP_NAME}.app found in DerivedData" >&2
  echo "       build the app in Xcode first (⌘B), then re-run." >&2
  exit 1
fi

BUILT_AT="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${SRC}")"
echo "source : ${SRC}"
echo "built  : ${BUILT_AT}"
echo "dest   : ${DEST}"

if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "quitting running ${APP_NAME}…"
  osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -x "${APP_NAME}" >/dev/null || break
    sleep 0.1
  done
  pgrep -x "${APP_NAME}" >/dev/null && pkill -x "${APP_NAME}" || true
fi

if [[ -d "${DEST}" ]]; then
  rm -rf "${DEST}"
fi

ditto "${SRC}" "${DEST}"
echo "installed."
codesign -dv "${DEST}" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" || true
