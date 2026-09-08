#!/bin/bash
set -euo pipefail

task_user_home="$(cd && pwd -P)"
task_support_dir="$task_user_home/Library/Application Support/CodexVoice"
task_bridge="$task_support_dir/bin/codex-voice-bridge"

if [[ ! -x "$task_bridge" ]]; then
    echo "Codex Voice is not installed." >&2
    exit 1
fi

"$task_bridge" revoke-devices --support-dir "$task_support_dir"
echo "Generate a fresh QR and pair again from the iPhone companion."
