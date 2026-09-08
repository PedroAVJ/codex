#!/bin/bash
set -euo pipefail

task_repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
task_workspace_dir="$(pwd -P)"
task_user_home="$(cd && pwd -P)"
task_support_dir="$task_user_home/Library/Application Support/CodexVoice"
task_bin_dir="$task_support_dir/bin"
task_log_dir="$task_support_dir/Logs"
task_service_name="Pedro Voice Agent on $(scutil --get ComputerName 2>/dev/null || hostname -s)"
task_service_name_file="$task_support_dir/service-name.txt"
task_pairing_qr="$task_support_dir/pairing-qr.png"
task_launch_agent="$task_user_home/Library/LaunchAgents/com.pedro.codexvoice.bridge.plist"
task_service="gui/$(id -u)/com.pedro.codexvoice.bridge"
task_swift_scratch_path="${CODEX_VOICE_SWIFT_SCRATCH_PATH:-$task_repo_dir/.build}"
task_open_qr=true
task_create_pairing_qr=true
task_relay_url="${CODEX_VOICE_RELAY_URL:-wss://codex-voice-relay.codex-voice-hibernating-relay.workers.dev/api/relay}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cwd)
            [[ $# -ge 2 ]] || { echo "--cwd requires a folder" >&2; exit 2; }
            task_workspace_dir="$2"
            shift 2
            ;;
        --service-name)
            [[ $# -ge 2 ]] || { echo "--service-name requires a value" >&2; exit 2; }
            task_service_name="$2"
            shift 2
            ;;
        --relay-url)
            [[ $# -ge 2 ]] || { echo "--relay-url requires a wss:// URL" >&2; exit 2; }
            task_relay_url="$2"
            shift 2
            ;;
        --no-open)
            task_open_qr=false
            shift
            ;;
        --no-pair)
            task_create_pairing_qr=false
            task_open_qr=false
            shift
            ;;
        *)
            echo "Usage: $0 [--cwd PATH] [--service-name NAME] [--relay-url WSS_URL] [--no-open] [--no-pair]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$task_workspace_dir" ]]; then
    echo "Workspace does not exist: $task_workspace_dir" >&2
    exit 1
fi

if [[ "$task_relay_url" != wss://* ]]; then
    echo "Relay URL must use wss://" >&2
    exit 1
fi

task_codex_binary="${CODEX_BINARY:-}"
if [[ -n "$task_codex_binary" && ! -x "$task_codex_binary" ]]; then
    echo "CODEX_BINARY is not executable: $task_codex_binary" >&2
    exit 1
fi
if [[ -z "$task_codex_binary" && -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
    task_codex_binary="/Applications/ChatGPT.app/Contents/Resources/codex"
fi
if [[ -z "$task_codex_binary" ]]; then
    task_codex_binary="$(command -v codex || true)"
fi
if [[ -z "$task_codex_binary" || ! -x "$task_codex_binary" ]]; then
    echo "A Codex CLI executable is required to run the local app-server daemon." >&2
    exit 1
fi

task_daemon_status="$("$task_codex_binary" app-server daemon version 2>/dev/null || true)"
if ! printf '%s' "$task_daemon_status" \
    | /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"'; then
    "$task_codex_binary" app-server daemon start >/dev/null
    task_daemon_status="$("$task_codex_binary" app-server daemon version)"
fi
if ! printf '%s' "$task_daemon_status" \
    | /usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"'; then
    echo "Codex app-server daemon did not reach running state." >&2
    exit 1
fi

cd "$task_repo_dir"
swift build \
    --scratch-path "$task_swift_scratch_path" \
    --disable-keychain \
    -c release \
    --jobs 1

mkdir -p "$task_bin_dir" "$task_log_dir" "$(dirname "$task_launch_agent")"
chmod 700 "$task_support_dir" "$task_bin_dir" "$task_log_dir"
install -m 755 "$task_swift_scratch_path/release/codex-voice-bridge" "$task_bin_dir/codex-voice-bridge"

task_signing_identity="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -n 1)"
if [[ -z "$task_signing_identity" ]]; then
    echo "An Apple Development signing identity is required for stable background Keychain access." >&2
    exit 1
fi
/usr/bin/codesign --force \
    --sign "$task_signing_identity" \
    --identifier com.pedro.codexvoice.bridge \
    --timestamp=none \
    "$task_bin_dir/codex-voice-bridge"

if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    printf '%s' "$OPENROUTER_API_KEY" | "$task_bin_dir/codex-voice-bridge" configure-openrouter-key >/dev/null
fi

task_status="$("$task_bin_dir/codex-voice-bridge" status --support-dir "$task_support_dir")"
if ! printf '%s' "$task_status" | rg -q '"openRouterAPIKeyConfigured"\s*:\s*true'; then
    echo "OpenRouter voice is not configured." >&2
    echo "Run scripts/configure-api-key.sh locally, then rerun this installer." >&2
    exit 1
fi

printf '%s\n' "$task_service_name" > "$task_service_name_file"
chmod 600 "$task_service_name_file"

task_plist_temp="$(mktemp -t codex-voice-launch-agent)"
trap 'rm -f "$task_plist_temp"' EXIT
plutil -create xml1 "$task_plist_temp"
plutil -insert Label -string com.pedro.codexvoice.bridge "$task_plist_temp"
plutil -insert ProgramArguments -array "$task_plist_temp"
plutil -insert ProgramArguments.0 -string "$task_bin_dir/codex-voice-bridge" "$task_plist_temp"
plutil -insert ProgramArguments.1 -string --cwd "$task_plist_temp"
plutil -insert ProgramArguments.2 -string "$task_workspace_dir" "$task_plist_temp"
plutil -insert ProgramArguments.3 -string --support-dir "$task_plist_temp"
plutil -insert ProgramArguments.4 -string "$task_support_dir" "$task_plist_temp"
plutil -insert ProgramArguments.5 -string --service-name "$task_plist_temp"
plutil -insert ProgramArguments.6 -string "$task_service_name" "$task_plist_temp"
plutil -insert ProgramArguments.7 -string --model "$task_plist_temp"
plutil -insert ProgramArguments.8 -string gpt-5.6-luna "$task_plist_temp"
plutil -insert ProgramArguments.9 -string --voice-model "$task_plist_temp"
plutil -insert ProgramArguments.10 -string openai/gpt-audio-mini "$task_plist_temp"
plutil -insert ProgramArguments.11 -string --relay-url "$task_plist_temp"
plutil -insert ProgramArguments.12 -string "$task_relay_url" "$task_plist_temp"
plutil -insert ProgramArguments.13 -string --codex-binary "$task_plist_temp"
plutil -insert ProgramArguments.14 -string "$task_codex_binary" "$task_plist_temp"
plutil -insert EnvironmentVariables -dictionary "$task_plist_temp"
plutil -insert EnvironmentVariables.PATH -string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin "$task_plist_temp"
plutil -insert RunAtLoad -bool true "$task_plist_temp"
plutil -insert KeepAlive -bool true "$task_plist_temp"
plutil -insert ProcessType -string Interactive "$task_plist_temp"
plutil -insert StandardOutPath -string "$task_log_dir/bridge.log" "$task_plist_temp"
plutil -insert StandardErrorPath -string "$task_log_dir/bridge-error.log" "$task_plist_temp"
plutil -lint "$task_plist_temp" >/dev/null
install -m 600 "$task_plist_temp" "$task_launch_agent"
rm -f "$task_plist_temp"
trap - EXIT

launchctl bootout "$task_service" 2>/dev/null || true
sleep 1
rm -f "$task_support_dir/relay-state.json"
launchctl bootstrap "gui/$(id -u)" "$task_launch_agent"
launchctl kickstart -k "$task_service"

task_relay_ready=false
for ((task_attempt = 0; task_attempt < 30; task_attempt++)); do
    task_live_status="$("$task_bin_dir/codex-voice-bridge" status --support-dir "$task_support_dir")"
    if printf '%s' "$task_live_status" | /usr/bin/grep -Eq '"relayConnected"[[:space:]]*:[[:space:]]*true'; then
        task_relay_ready=true
        break
    fi
    sleep 1
done

if [[ "$task_relay_ready" != true ]]; then
    echo "Codex Voice could not connect to the remote relay." >&2
    echo "Check $task_log_dir/bridge-error.log" >&2
    exit 1
fi

if [[ "$task_create_pairing_qr" == true ]]; then
    "$task_bin_dir/codex-voice-bridge" pair \
        --support-dir "$task_support_dir" \
        --service-name "$task_service_name" \
        --relay-url "$task_relay_url" \
        --output "$task_pairing_qr"

    if [[ "$task_open_qr" == true ]]; then
        open "$task_pairing_qr"
    fi
fi

echo "Pedro Voice Agent bridge is installed and running."
echo "Workspace: $task_workspace_dir"
echo "Codex app-server daemon: running"
echo "Remote relay: connected"
if [[ "$task_create_pairing_qr" == true ]]; then
    echo "Pairing QR: $task_pairing_qr"
fi
echo "Logs: $task_log_dir"
