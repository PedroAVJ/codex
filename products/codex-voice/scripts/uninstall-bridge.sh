#!/bin/bash
set -euo pipefail

task_user_home="$(cd && pwd -P)"
task_support_dir="$task_user_home/Library/Application Support/CodexVoice"
task_launch_agent="$task_user_home/Library/LaunchAgents/com.pedro.codexvoice.bridge.plist"
task_service="gui/$(id -u)/com.pedro.codexvoice.bridge"

launchctl bootout "$task_service" 2>/dev/null || true
if [[ -f "$task_launch_agent" ]]; then
    mv "$task_launch_agent" "$task_launch_agent.disabled"
fi

echo "Codex Voice bridge stopped."
echo "Keys, paired-device state, logs, and the disabled LaunchAgent remain in $task_support_dir."
