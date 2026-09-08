#!/bin/bash
set -euo pipefail

task_user_home="$(cd && pwd -P)"
task_support_dir="$task_user_home/Library/Application Support/CodexVoice"
task_bridge="$task_support_dir/bin/codex-voice-bridge"
task_service_name_file="$task_support_dir/service-name.txt"
task_pairing_qr="$task_support_dir/pairing-qr.png"

if [[ ! -x "$task_bridge" ]]; then
    echo "Codex Voice is not installed. Run scripts/install-bridge.sh first." >&2
    exit 1
fi

if [[ -f "$task_service_name_file" ]]; then
    task_service_name="$(head -n 1 "$task_service_name_file")"
else
    task_service_name="Pedro Voice Agent on $(scutil --get ComputerName 2>/dev/null || hostname -s)"
fi

"$task_bridge" pair \
    --support-dir "$task_support_dir" \
    --service-name "$task_service_name" \
    --output "$task_pairing_qr"
open "$task_pairing_qr"
