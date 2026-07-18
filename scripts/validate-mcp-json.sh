#!/bin/bash
# Validates a project-scope .mcp.json against the Claude Code format.
# Reference: https://code.claude.com/docs/en/mcp (Project scope)
#
# Claude Code publishes no JSON Schema for .mcp.json, so this script enforces
# the documented structure locally, then defers to `claude mcp list` — the only
# official validator — when the CLI is installed (advisory, non-blocking).
#
# Usage: scripts/validate-mcp-json.sh [project-dir]

set -euo pipefail

project_dir="${1:-.}"
config="$project_dir/.mcp.json"

if [[ ! -f "$config" ]]; then
  echo "error: $config not found" >&2
  exit 1
fi

python3 - "$config" <<'EOF'
import json, sys

path = sys.argv[1]
try:
    with open(path) as f:
        root = json.load(f)
except json.JSONDecodeError as e:
    print(f"error: {path}: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

errors = []
servers = root.get("mcpServers")
if not isinstance(servers, dict):
    errors.append('top-level "mcpServers" object is missing')
else:
    for name, server in servers.items():
        if not isinstance(server, dict):
            errors.append(f"{name}: entry must be an object")
            continue
        stype = server.get("type")
        if stype is not None and stype not in ("stdio", "http", "sse", "ws", "streamable-http"):
            errors.append(f"{name}: unsupported type {stype!r} (want stdio/http/sse/ws)")
        for foreign in ("enabled", "transport", "cwd"):
            if foreign in server:
                errors.append(f'{name}: "{foreign}" is not a valid .mcp.json key')
        if stype in (None, "stdio"):
            cmd = server.get("command")
            if not isinstance(cmd, str) or not cmd:
                errors.append(f'{name}: stdio server needs "command" as a string')
            args = server.get("args")
            if args is not None and (not isinstance(args, list) or not all(isinstance(a, str) for a in args)):
                errors.append(f'{name}: "args" must be an array of strings')
            if server.get("url") is not None and stype is None:
                errors.append(f'{name}: has "url" but no "type"; add "type": "http" (or "sse"/"ws")')
        else:
            url = server.get("url")
            if not isinstance(url, str) or not url.startswith(("http://", "https://")):
                errors.append(f'{name}: remote server needs an http(s) "url"')
        for key in ("env", "headers"):
            m = server.get(key)
            if m is not None and (not isinstance(m, dict) or not all(isinstance(v, str) for v in m.values())):
                errors.append(f'{name}: "{key}" must be a string map')

if errors:
    for e in errors:
        print(f"error: {path}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"ok: {path} structure is valid")
EOF

if command -v claude >/dev/null 2>&1; then
  echo "== claude mcp list (official validator, advisory) =="
  (cd "$project_dir" && claude mcp list) || echo "warning: claude mcp list reported problems (see above)"
fi
