#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# pet 运动 runtime 已纯 Swift 化(LocalRuntimeClient),Rust weather_motion_runtime
# 已退役 —— 无需 cargo 预构建。
swift test --package-path "$ROOT_DIR"
swift build --package-path "$ROOT_DIR"
