#!/bin/zsh
set -euo pipefail

LAUNCH_AGENT="$HOME/Library/LaunchAgents/local.codex.taskforge-reminder-sync.plist"
INSTALLED_APP="$HOME/Applications/TaskForgeReminderSync.app"
USER_DOMAIN="gui/$(id -u)"

if [[ -f "$LAUNCH_AGENT" ]]; then
  launchctl bootout "$USER_DOMAIN" "$LAUNCH_AGENT" 2>/dev/null || true
  rm "$LAUNCH_AGENT"
fi
if [[ -d "$INSTALLED_APP" ]]; then
  rm -rf "$INSTALLED_APP"
fi

print -r -- "已移除自动运行配置和已安装 App。"
print -r -- "已经写入 Apple 提醒事项的内容不会被删除。"
