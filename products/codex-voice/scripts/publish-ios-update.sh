#!/usr/bin/env bash
set -euo pipefail

message="Codex Voice production update $(git rev-parse --short=12 HEAD)"
if [ "${1:-}" = "--message" ]; then
  if [ -z "${2:-}" ]; then
    echo "Usage: $0 [--message MESSAGE]" >&2
    exit 64
  fi
  message="$2"
  shift 2
fi

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--message MESSAGE]" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
cd "$project_root"

if [ -n "$(git status --porcelain=v1)" ]; then
  echo "Commit or remove local changes before publishing Codex Voice." >&2
  exit 1
fi

eas=(npx --yes eas-cli@22.2.0)

echo "==> Checking Codex Voice update contracts"
node --test tests/*.test.mjs
npm run export:ios
npx expo-updates configuration:syncnative --platform ios --workflow generic
git diff --exit-code -- ios

echo "==> Publishing the production iOS update"
"${eas[@]}" update \
  --channel production \
  --platform ios \
  --environment production \
  --message "$message" \
  --non-interactive

echo "Codex Voice production update published. Native compilation was not started."
