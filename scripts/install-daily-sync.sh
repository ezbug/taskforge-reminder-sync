#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_APP="$PROJECT_ROOT/dist/TaskForgeReminderSync.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/TaskForgeReminderSync.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENTS_DIR/local.codex.taskforge-reminder-sync.plist"
LOG_DIR="$HOME/Library/Logs"
LABEL="local.codex.taskforge-reminder-sync"
USER_DOMAIN="gui/$(id -u)"

if [[ ! -d "$BUILD_APP" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi
codesign --verify --deep --strict "$BUILD_APP"

mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
if [[ -e "$INSTALLED_APP" ]]; then
  rm -rf "$INSTALLED_APP"
fi
ditto "$BUILD_APP" "$INSTALLED_APP"

install -m 644 \
  "$PROJECT_ROOT/Resources/local.codex.taskforge-reminder-sync.plist" \
  "$LAUNCH_AGENT"

/usr/libexec/PlistBuddy \
  -c "Set :ProgramArguments:1 $INSTALLED_APP/Contents/Resources/TaskForgeReminderSyncLauncher" \
  "$LAUNCH_AGENT"
plutil -replace StandardOutPath \
  -string "$LOG_DIR/TaskForgeReminderSync.log" \
  "$LAUNCH_AGENT"
plutil -replace StandardErrorPath \
  -string "$LOG_DIR/TaskForgeReminderSync.error.log" \
  "$LAUNCH_AGENT"
plutil -lint "$LAUNCH_AGENT"

launchctl bootout "$USER_DOMAIN" "$LAUNCH_AGENT" 2>/dev/null || true
launchctl bootstrap "$USER_DOMAIN" "$LAUNCH_AGENT"

print -r -- "已安装：$INSTALLED_APP"
print -r -- "已启用 TaskForge ↔ Apple 提醒事项近实时双向同步。"
print -r -- "Apple 变化约 1 秒响应，TaskForge 变化约 1 秒检查，并有每分钟与 07:00/11:00/15:00 兜底。"
print -r -- "日志：$LOG_DIR/TaskForgeReminderSync.log"
