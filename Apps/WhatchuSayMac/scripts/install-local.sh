#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WhatchuSayMac"
DEST="/Applications/${APP_NAME}.app"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData"
BIN_REL="Contents/MacOS/${APP_NAME}"

# Stable code-signing identity. macOS pins Accessibility / PostEvent grants to
# the app's signing identity, so every install must use the SAME certificate or
# the permission is lost. Xcode signs Debug builds with an Apple Development cert
# that Gatekeeper reads as revoked ("…will damage your computer" on reboot), and
# an ad-hoc signature's hash changes on every build — so we re-sign with a stable
# self-signed cert here. Override with SIGN_IDENTITY=... if you use a different one.
SIGN_IDENTITY="${SIGN_IDENTITY:-WhatchuSay Dev}"

if ! security find-identity -p codesigning 2>/dev/null | grep -qF "${SIGN_IDENTITY}"; then
  echo "error: code-signing identity \"${SIGN_IDENTITY}\" not found in keychain." >&2
  echo "       create a self-signed 'Code Signing' certificate with that name" >&2
  echo "       (Keychain Access ▸ Certificate Assistant), or set SIGN_IDENTITY=..." >&2
  exit 1
fi

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
echo "signer : ${SIGN_IDENTITY}"

if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "quitting running ${APP_NAME}…"
  osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -x "${APP_NAME}" >/dev/null || break
    sleep 0.1
  done
  pgrep -x "${APP_NAME}" >/dev/null && pkill -x "${APP_NAME}" || true
fi

# Stage to a temp dir and sign there. In-place signing of an app already in
# /Applications is blocked by App Management ("Operation not permitted"), so we
# sign the staged copy and then swap it in.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-install.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
APP="${STAGE}/${APP_NAME}.app"
ditto "${SRC}" "${APP}"

echo "signing…"
xattr -cr "${APP}"
# Sign nested Mach-O (debug/preview dylibs in Debug builds) before the bundle.
for dylib in "${APP}/Contents/MacOS/"*.dylib; do
  [[ -e "${dylib}" ]] && codesign --force --timestamp=none --sign "${SIGN_IDENTITY}" "${dylib}"
done
codesign --force --timestamp=none --sign "${SIGN_IDENTITY}" "${APP}"
codesign --verify --strict "${APP}"

if [[ -d "${DEST}" ]]; then
  rm -rf "${DEST}"
fi

ditto "${APP}" "${DEST}"
echo "installed."
codesign -dv "${DEST}" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" || true
echo "note: first install with a new cert needs a one-time Accessibility grant;"
echo "      after that the permission persists across rebuilds and reboots."
