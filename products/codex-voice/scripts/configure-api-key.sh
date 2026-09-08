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

if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf '%s' "$OPENROUTER_API_KEY" | "$task_bridge" configure-openrouter-key
    exit 0
fi

if [[ ! -t 0 ]]; then
    echo "Set OPENROUTER_API_KEY or run this script directly in Terminal for a hidden prompt." >&2
    exit 1
fi

read -r -s -p "OpenRouter API key: " task_api_key
printf '\n'
printf '%s' "$task_api_key" | "$task_bridge" configure-openrouter-key
unset task_api_key
