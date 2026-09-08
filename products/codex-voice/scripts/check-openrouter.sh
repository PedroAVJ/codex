#!/bin/bash
set -euo pipefail

task_repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
task_user_home="$(cd && pwd -P)"
task_installed_binary="$task_user_home/Library/Application Support/CodexVoice/bin/codex-voice-bridge"

if [[ -x "$task_installed_binary" ]] \
    && "$task_installed_binary" --help 2>&1 | /usr/bin/grep -q 'OpenRouter audio voice'; then
    task_bridge="$task_installed_binary"
else
    cd "$task_repo_dir"
    swift build -c release --jobs 1
    task_bridge="$task_repo_dir/.build/release/codex-voice-bridge"
fi

"$task_bridge" check-openrouter
