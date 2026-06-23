#!/usr/bin/env bash
# setup-cubism.sh — 工作块 D:把官方 Cubism SDK for Native 解进 gitignored Vendor/Cubism/。
#
# 为什么要这个脚本:Cubism Core 是 Live2D **专有许可二进制**,不能入库。每个开发者
# 自己去 https://www.live2d.com/en/sdk/download/native/ 下官方 SDK(接受许可,免费),
# 跑本脚本解到 Vendor/Cubism/。Package.swift 检测该目录存在 → 启用 Live2D target,
# 不存在 → 优雅跳过(无 Live2D 也能正常 build)。
#
# 用法:  scripts/setup-cubism.sh [CubismSdkForNative-*.zip]
#         缺省找 ~/Downloads/CubismSdkForNative-*.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/Cubism"

ZIP="${1:-}"
if [[ -z "$ZIP" ]]; then
  ZIP="$(ls -t "$HOME"/Downloads/CubismSdkForNative-*.zip 2>/dev/null | head -1 || true)"
fi
[[ -n "$ZIP" && -f "$ZIP" ]] || { echo "✗ 找不到 SDK zip。用法: $0 <CubismSdkForNative-*.zip>"; exit 1; }
echo "📦 SDK: $ZIP"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# 只解需要的部分(Core 头/macOS 静态库 + Framework 源 + 许可 + 一个示例模型),其它平台跳过。
# Hiyori 样本仅作 D-2.1 模型解析无头测的本地 fixture(gitignored 不入仓;Live2DTests 仅在
# Vendor 存在时编 → setup 跑过即有此 fixture,测试确定可用)。
unzip -q "$ZIP" '*/Core/include/*' '*/Core/lib/macos/*' '*/Framework/src/*' \
  '*/Samples/Resources/Hiyori/*' \
  '*/Core/LICENSE.md' '*/Framework/LICENSE.md' '*/LICENSE.md' -d "$TMP"
SDK="$(find "$TMP" -maxdepth 1 -type d -name 'CubismSdkForNative-*' | head -1)"
[[ -n "$SDK" ]] || { echo "✗ zip 结构异常"; exit 1; }

rm -rf "$DEST"; mkdir -p "$DEST/Core/lib" "$DEST/Core/include" "$DEST/Framework" "$DEST/Samples"
cp -R "$SDK/Core/include/." "$DEST/Core/include/"
cp -R "$SDK/Framework/src" "$DEST/Framework/src"
[[ -d "$SDK/Samples/Resources/Hiyori" ]] && cp -R "$SDK/Samples/Resources/Hiyori" "$DEST/Samples/Hiyori"

# Core C 头复制进 CubismCore target 的 include/(本地解析,gitignored);shim 模块 #include 它。
cp "$SDK/Core/include/Live2DCubismCore.h" "$ROOT/Sources/CubismCore/include/Live2DCubismCore.h"
cp "$SDK/Core/LICENSE.md" "$DEST/Core/LICENSE.md" 2>/dev/null || true
cp "$SDK/Framework/LICENSE.md" "$DEST/Framework/LICENSE.md" 2>/dev/null || true

# 把 macOS arm64 + x86_64 静态库 lipo 成 universal,Package.swift 只链一个路径(免按架构分叉)。
ARM="$SDK/Core/lib/macos/arm64/libLive2DCubismCore.a"
X64="$SDK/Core/lib/macos/x86_64/libLive2DCubismCore.a"
if [[ -f "$ARM" && -f "$X64" ]]; then
  lipo -create "$ARM" "$X64" -output "$DEST/Core/lib/libLive2DCubismCore.a"
elif [[ -f "$ARM" ]]; then
  cp "$ARM" "$DEST/Core/lib/libLive2DCubismCore.a"
else
  echo "✗ 没找到 macOS 静态库(Core/lib/macos/arm64)"; exit 1
fi

echo "✅ Cubism SDK 已装到 Vendor/Cubism/(gitignored)"
echo "   universal lib: $(lipo -archs "$DEST/Core/lib/libLive2DCubismCore.a" 2>/dev/null || echo '?')"

# D-2.2:编 Cubism Metal renderer 运行时按名加载的 metallib(需 Metal Toolchain)。
# 缺 toolchain 不阻塞 setup —— framework/Core 已就位,Live2D 模型仍能装+解析(D-1/D-2.1),
# 只是渲染(D-2.2)缺 metallib 不出图。装 toolchain 后单独跑 build-cubism-metallibs.sh 即可。
if xcrun -sdk macosx metal -v >/dev/null 2>&1; then
  echo "🎭 编 Cubism Metal renderer metallib…"
  "$ROOT/scripts/build-cubism-metallibs.sh" || echo "   ⚠️ metallib 构建失败(不阻塞,可后续单独跑)"
else
  echo "   ⏭  跳过 metallib(Metal Toolchain 未装:xcodebuild -downloadComponent MetalToolchain)"
fi
echo "   重新 swift build 即启用 Live2D target;build.sh 会把 metallib 拷进 .app。"
