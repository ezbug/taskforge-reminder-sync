#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
OUTPUT_DIR=${1:-"$PROJECT_ROOT/dist"}
APP_PATH="$OUTPUT_DIR/TaskForgeReminderSync.app"
TASKFORGE_SYNC_SIGNING_IDENTITY=${TASKFORGE_SYNC_CODESIGN_IDENTITY:--}

swift build \
  --package-path "$PROJECT_ROOT" \
  --configuration release

BIN_DIR=$(swift build \
  --package-path "$PROJECT_ROOT" \
  --configuration release \
  --show-bin-path)

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_PATH" ]]; then
  rm -rf "$APP_PATH"
fi
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

install -m 755 \
  "$BIN_DIR/TaskForgeReminderSync" \
  "$APP_PATH/Contents/MacOS/TaskForgeReminderSync"
install -m 644 \
  "$PROJECT_ROOT/Resources/TaskForgeReminderSyncLauncher" \
  "$APP_PATH/Contents/Resources/TaskForgeReminderSyncLauncher"
install -m 644 \
  "$PROJECT_ROOT/Resources/Info.plist" \
  "$APP_PATH/Contents/Info.plist"

codesign \
  --force \
  --sign "$TASKFORGE_SYNC_SIGNING_IDENTITY" \
  --identifier local.codex.taskforge-reminder-sync \
  "$APP_PATH"

plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict "$APP_PATH"
print -r -- "$APP_PATH"
