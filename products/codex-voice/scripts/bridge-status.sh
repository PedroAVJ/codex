#!/bin/bash
set -euo pipefail

task_user_home="$(cd && pwd -P)"
task_support_dir="$task_user_home/Library/Application Support/CodexVoice"
task_bridge="$task_support_dir/bin/codex-voice-bridge"
task_service="gui/$(id -u)/com.pedro.codexvoice.bridge"

task_codex_binary="${CODEX_BINARY:-}"
if [[ -z "$task_codex_binary" && -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
    task_codex_binary="/Applications/ChatGPT.app/Contents/Resources/codex"
fi
if [[ -z "$task_codex_binary" ]]; then
    task_codex_binary="$(command -v codex || true)"
fi

if [[ ! -x "$task_bridge" ]]; then
    echo '{"installed":false,"running":false}'
    exit 1
fi

task_running=false
task_launch_state="$(launchctl print "$task_service" 2>/dev/null || true)"
if printf '%s\n' "$task_launch_state" | /usr/bin/grep -Eq '^[[:space:]]*state = running$' \
    && printf '%s\n' "$task_launch_state" | /usr/bin/grep -Eq '^[[:space:]]*pid = [0-9]+$'; then
    task_running=true
fi

task_status="$("$task_bridge" status --support-dir "$task_support_dir")"
task_daemon_running=false
if [[ -n "$task_codex_binary" && -x "$task_codex_binary" ]]; then
    task_daemon_status="$("$task_codex_binary" app-server daemon version 2>/dev/null || true)"
    if printf '%s' "$task_daemon_status" \
        | /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"'; then
        task_daemon_running=true
    fi
fi

task_relay_fresh=false
task_relay_updated_at="$(printf '%s\n' "$task_status" \
    | /usr/bin/sed -n 's/.*"relayStateUpdatedAt"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
if printf '%s' "$task_status" \
        | /usr/bin/grep -Eq '"relayConnected"[[:space:]]*:[[:space:]]*true' \
    && [[ "$task_relay_updated_at" =~ ^[0-9]+$ ]]; then
    task_relay_age=$(($(date +%s) - task_relay_updated_at))
    if ((task_relay_age >= 0 && task_relay_age <= 120)); then
        task_relay_fresh=true
    fi
fi

printf '%s\n' "$task_status"
echo "Codex app-server daemon running: $task_daemon_running"
echo "LaunchAgent running: $task_running"
echo "Relay state fresh: $task_relay_fresh"
echo "Logs: $task_support_dir/Logs"
