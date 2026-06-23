#!/usr/bin/env bash
# build-cubism-metallibs.sh — 工作块 D D-2.2:把 Cubism Metal renderer 的 shader 编成它运行时
# 按名加载的 `.metallib`,输出到 gitignored `Vendor/Cubism/FrameworkMetallibs/`。
#
# 为什么要这个脚本:`CubismShader_Metal.mm` 运行时从 `[NSBundle mainBundle]/.../FrameworkMetallibs/`
# 按名加载预编 metallib(`newLibraryWithURL`,不支持运行时源码编译)。SwiftPM 无 CMake 的
# metal→air→metallib custom_command → 我们自建。**精确复刻** SDK `Framework/src/Rendering/Metal/
# Shaders/CMakeLists.txt` 的命名 + blend 矩阵 + `-D` 索引,renderer 才能逐一找到。
#
# 需 Metal Toolchain(Xcode 26 拆成单独组件):缺则 `xcrun metal` 报错 → 先跑
#   xcodebuild -downloadComponent MetalToolchain
#
# install.sh / build.sh 之后把产物拷进 PetAgent.app/Contents/Resources/FrameworkMetallibs/。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SH="$ROOT/Vendor/Cubism/Framework/src/Rendering/Metal/Shaders"
OUT="$ROOT/Vendor/Cubism/FrameworkMetallibs"
SDK="macosx"

[[ -d "$SH" ]] || { echo "✗ 缺 Cubism Framework shader 源($SH);先跑 scripts/setup-cubism.sh"; exit 1; }
if ! xcrun -sdk "$SDK" metal -v >/dev/null 2>&1; then
  echo "✗ Metal Toolchain 不可用。先跑:xcodebuild -downloadComponent MetalToolchain"; exit 1
fi

rm -rf "$OUT"; mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 单文件编一个 metallib(无 -D)。$1=源 stem。
compile_one() {
  local stem="$1"; shift
  xcrun -sdk "$SDK" metal "$@" -I "$SH" -o "$TMP/$stem.air" -c "$SH/$stem.metal"
  xcrun -sdk "$SDK" metallib -o "$OUT/$stem.metallib" "$TMP/$stem.air"
}

# ① normal_shader_files —— 各编一次,无 -D,输出 <stem>.metallib(CMake normal_shader_files)。
echo "📦 normal shaders…"
for s in MetalShaders VertShaderSrcBlend VertShaderSrcMaskedBlend; do compile_one "$s"; done

# ② blend_shader_files × (16 color × 5 alpha − Normal/Over) —— 带 -D,输出 <stem><Color><Alpha>.metallib
#    (CMake blend_shader_files + 双重 foreach + continue Normal/Over)。
COLORS=(Normal Add AddGlow Darken Multiply ColorBurn LinearBurn Lighten Screen ColorDodge Overlay SoftLight HardLight LinearLight Hue Color)
ALPHAS=(Over Atop Out ConjointOver DisjointOver)
BLEND_FILES=(FragShaderSrcBlend FragShaderSrcMaskBlend FragShaderSrcMaskInvertedBlend \
  FragShaderSrcMaskInvertedPremultipliedAlphaBlend FragShaderSrcMaskPremultipliedAlphaBlend \
  FragShaderSrcPremultipliedAlphaBlend)

echo "📦 blend matrix(6 × 79)…"
count=0
for base in "${BLEND_FILES[@]}"; do
  for ci in "${!COLORS[@]}"; do
    for ai in "${!ALPHAS[@]}"; do
      [[ "${COLORS[$ci]}" == "Normal" && "${ALPHAS[$ai]}" == "Over" ]] && continue
      out="$base${COLORS[$ci]}${ALPHAS[$ai]}"
      xcrun -sdk "$SDK" metal -D "CSM_COLOR_BLEND_MODE=$ci" -D "CSM_ALPHA_BLEND_MODE=$ai" \
        -I "$SH" -o "$TMP/$out.air" -c "$SH/$base.metal"
      xcrun -sdk "$SDK" metallib -o "$OUT/$out.metallib" "$TMP/$out.air"
      count=$((count+1))
    done
  done
done

echo "✅ metallib 已生成到 Vendor/Cubism/FrameworkMetallibs/($(ls "$OUT" | wc -l | tr -d ' ') 个;normal 3 + blend $count)"
echo "   install.sh / build.sh 会拷进 PetAgent.app/Contents/Resources/FrameworkMetallibs/。"
