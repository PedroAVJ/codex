#!/usr/bin/env python3
"""Read one Codex role registry; never modify configuration or launch agents."""

import argparse
import json
import os
from pathlib import Path
import sys
import tomllib


def read_toml(path):
    with path.open("rb") as source:
        return tomllib.load(source)


def read_roles(config_path, selected=None):
    config_path = config_path.expanduser().resolve()
    agents = read_toml(config_path).get("agents", {})
    if not isinstance(agents, dict):
        raise ValueError("agents must be a TOML table")
    roles = {}
    for key, registration in agents.items():
        if not isinstance(registration, dict):
            continue  # Global agent settings are not role registrations.
        if not any(field in registration for field in ("description", "config_file")):
            continue
        description = registration.get("description", "")
        relative = registration.get("config_file")
        if not isinstance(description, str) or (relative is not None and not isinstance(relative, str)):
            raise ValueError(f"Invalid registration for role {key}")
        path = None
        if relative is not None:
            if not relative.strip():
                raise ValueError(f"Empty config_file for role {key}")
            path = (config_path.parent / Path(relative).expanduser()).resolve()
        roles[key] = {
            "key": key,
            "description": description,
            "config_file": str(path) if path else None,
        }
    result = {"registry_file": str(config_path), "merges_config_layers": False}
    if selected is None:
        return {**result, "roles": list(roles.values())}
    if selected not in roles:
        raise ValueError(f"Role is not registered: {selected}")
    role = roles[selected]
    role_config = read_toml(Path(role["config_file"])) if role["config_file"] else {}
    return {**result, "role": {**role, "config": role_config}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "config.toml")
    parser.add_argument("--role", help="Exact registered role key; omit to list registrations")
    args = parser.parse_args()
    try:
        result = read_roles(args.config, args.role)
    except (OSError, ValueError) as error:
        # TOML parse errors can contain private source text; do not echo them.
        message = "Invalid TOML configuration" if isinstance(error, tomllib.TOMLDecodeError) else str(error)
        print(json.dumps({"error": message}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
