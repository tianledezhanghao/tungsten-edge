#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="macos-dock-cc-v2"
CLI_NAME="window-lab"
PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/macos-dock-cc-v2.xcodeproj"
DERIVED_DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Debug uses a persistent local identity; never borrow the publisher's Developer ID.
LOCAL_SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY:-macos-dock-cc Local Code Signing}"
BUILD_LOG="/tmp/macos-dock-cc-v2-build.log"
SIGN_LOG="/tmp/macos-dock-cc-v2-codesign.log"

check_signing() {
  local identities
  xcodebuild -version >/dev/null
  identities="$(security find-identity -v -p codesigning)"
  if ! grep -Fq "\"$LOCAL_SIGNING_IDENTITY\"" <<<"$identities"; then
    echo "error: local signing identity '$LOCAL_SIGNING_IDENTITY' is not available." >&2
    echo "Create/trust it in Keychain Access, including its private key; see Docs/local-development.md." >&2
    echo "No app has been stopped or launched. No certificate or trust settings were changed." >&2
    return 1
  fi
}

build_debug() {
  if ! xcodebuild -project "$PROJECT_PATH" -scheme "$1" -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGN_IDENTITY="$LOCAL_SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    build >"$BUILD_LOG" 2>&1; then
    tail -n 80 "$BUILD_LOG" >&2
    echo "Full build log: $BUILD_LOG" >&2
    return 1
  fi
}

build_app() {
  check_signing
  # Force the universal product to be re-created on every build. After an `xcodebuild test` has
  # already relinked the per-arch binaries, a plain build can skip CreateUniversalBinary and leave
  # the previous executable in the .app (re-signed below, so its mtime looks fresh) — the launched
  # app then runs old code while the build log says BUILD SUCCEEDED.
  rm -f "$APP_EXECUTABLE"
  build_debug "$APP_NAME"
}

sign_app() {
  local identity="$LOCAL_SIGNING_IDENTITY" nested
  # Keep nested Sparkle code on the same identity as the host. Preserve Debug's
  # entitlements (including get-task-allow); do not enable hardened runtime.
  : >"$SIGN_LOG"
  trap 'echo "Signing failed; see /tmp/macos-dock-cc-v2-codesign.log" >&2' ERR
  local framework="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$framework" ]]; then
    for nested in "$framework/Versions/B/Updater.app" "$framework/Versions/B/Autoupdate" \
      "$framework"/Versions/B/XPCServices/*.xpc; do
      [[ -e "$nested" ]] && /usr/bin/codesign --force --sign "$identity" --timestamp=none --preserve-metadata=entitlements "$nested" >>"$SIGN_LOG" 2>&1
    done
    /usr/bin/codesign --force --sign "$identity" --timestamp=none --preserve-metadata=entitlements "$framework" >>"$SIGN_LOG" 2>&1
  fi
  /usr/bin/codesign --force --sign "$identity" --timestamp=none --preserve-metadata=entitlements "$APP_BUNDLE" >>"$SIGN_LOG" 2>&1
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  trap - ERR
  echo "Signed Debug app: $APP_BUNDLE"
}

run_cli() {
  build_debug "$CLI_NAME"
  "$DERIVED_DATA_DIR/Build/Products/Debug/$CLI_NAME" "$@"
}

# Only stop this checkout's Debug executable, never the installed application.
dev_pids() {
  local pid executable
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    [[ "$executable" != "$APP_EXECUTABLE" ]] || echo "$pid"
  done < <(pgrep -x "$APP_NAME" || true)
}

stop_app() {
  local pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] || kill "$pid"
  done < <(dev_pids)
  wait_for_exit
}

wait_for_exit() {
  local attempt
  for attempt in $(seq 1 25); do
    [[ -n "$(dev_pids)" ]] || return 0
    sleep 0.2
  done
  echo "error: this checkout's Debug process did not exit; quit it and retry." >&2
  return 1
}

open_app() {
  wait_for_exit
  /usr/bin/open "$APP_BUNDLE"
}

wait_for_app() {
  local attempt
  for attempt in $(seq 1 20); do
    if [[ -n "$(dev_pids)" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

case "$MODE" in
  run)
    build_app
    sign_app
    stop_app
    open_app
    ;;
  --build|build)
    build_app
    sign_app
    ;;
  --check-signing|check-signing)
    check_signing
    echo "Local signing identity is available: $LOCAL_SIGNING_IDENTITY"
    ;;
  --debug|debug)
    build_app
    sign_app
    stop_app
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    build_app
    sign_app
    stop_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_app
    sign_app
    stop_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.caye.macosdockcc.v2\""
    ;;
  --launch-trace|launch-trace)
    build_app
    sign_app
    stop_app
    DOCK_LAUNCH_TRACE=1 "$APP_EXECUTABLE" > /tmp/launch-trace.log 2>&1 &
    wait_for_app
    echo "launch trace: /tmp/launch-trace.log"
    ;;
  --verify|verify)
    build_app
    sign_app
    stop_app
    open_app
    wait_for_app
    ;;
  --lab|lab)
    run_cli "${@:2}"
    ;;
  --lab-minimize|lab-minimize)
    run_cli minimizeRestore "${@:2}"
    ;;
  --lab-close|lab-close)
    run_cli closeTarget "${@:2}"
    ;;
  --lab-replay|lab-replay)
    run_cli replay "${2:-minimize-restore-replay}"
    ;;
  --lab-placement|lab-placement)
    run_cli placementReplay "${2:-placement-permanent-hold-replay}"
    ;;
  --lab-transition|lab-transition)
    run_cli transitionReplay "${2:-focused-active-replay}"
    ;;
  *)
    echo "usage: $0 [run|--build|--check-signing|--debug|--logs|--telemetry|--launch-trace|--verify|--lab|--lab-minimize|--lab-close|--lab-replay [scenario-name]|--lab-placement [scenario-name]|--lab-transition [scenario-name]]" >&2
    exit 2
    ;;
esac
