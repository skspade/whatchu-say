#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WhatchuSayMac"
DEST="/Applications/${APP_NAME}.app"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData"
BIN_REL="Contents/MacOS/${APP_NAME}"

# Select by the inner Mach-O binary's mtime, not the .app directory's.
# macOS does not bump a bundle dir's mtime on incremental rebuilds that only
# rewrite Contents/MacOS/*, so the dir mtime under-reports build freshness and
# can pick a stale build when several exist.
BIN="$(find "${DERIVED}" \
        -path "*/Build/Products/Debug/${APP_NAME}.app/${BIN_REL}" \
        -not -path "*Index.noindex*" \
        -type f -print0 2>/dev/null \
      | xargs -0 stat -f "%m %N" \
      | sort -rn \
      | head -1 \
      | cut -d' ' -f2-)"

if [[ -z "${BIN}" || ! -f "${BIN}" ]]; then
  echo "error: no Debug build of ${APP_NAME}.app found in DerivedData" >&2
  echo "       build the app in Xcode first (⌘B), then re-run." >&2
  exit 1
fi

SRC="${BIN%/${BIN_REL}}"
BUILT_AT="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${BIN}")"
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
