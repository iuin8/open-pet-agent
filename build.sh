#!/bin/bash
# build.sh — 编译 OpenPetAgent.app + 用本地证书签名让 TCC 权限稳定
#
# 借鉴 HermesPet 决策 #4 (CLAUDE.md):
# - ad-hoc 签名 (codesign --sign -):每次构建 CDHash 变 → TCC 把每次 build 当
#   成新 app → Accessibility / 截屏权限丢失,每次启动重新弹窗授权
# - 用本地 Apple Development 证书签名:TCC 认 (TeamID + BundleID) 而非
#   CDHash → 重 build 也认得是同一个 app → **权限永久稳定**
# - 没证书时 fallback 到 ad-hoc + 警告 (比 unsigned 稳一些,但不是绝对)
#
# 用法:
#   ./build.sh         编译 + 签名,产物在 OpenPetAgent.app
#   ./install.sh       本脚本 + 覆盖装到 /Applications + 启动 (日常用这个)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="OpenPetAgent"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "🏗️  Building $APP_NAME (release, arm64)..."
swift build -c release --arch arm64

BINARY="$SCRIPT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    # SwiftPM 在 single-arch build 时产物路径会少一层
    BINARY="$SCRIPT_DIR/.build/release/$APP_NAME"
fi
if [ ! -f "$BINARY" ]; then
    echo "❌ 找不到 release binary,预期路径: .build/arm64-apple-macosx/release/$APP_NAME"
    exit 1
fi

echo "📦 Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 工作块 D D-2.2:Live2D 渲染需 Cubism Metal renderer 的预编 metallib。renderer 运行时从
# [NSBundle mainBundle]/Contents/Resources/FrameworkMetallibs/ 按名加载 → 拷进 bundle。
# metallib 由 scripts/build-cubism-metallibs.sh 生成到 gitignored Vendor(需 Metal Toolchain)。
# 没有(没装 SDK / 没编)则跳过 → app 照常跑,只是 Live2D 形象渲染不出(选中显占位)。
METALLIBS="$SCRIPT_DIR/Vendor/Cubism/FrameworkMetallibs"
if [ -d "$METALLIBS" ] && ls "$METALLIBS"/*.metallib >/dev/null 2>&1; then
    echo "🎭 拷 Cubism metallib 进 bundle ($(ls "$METALLIBS"/*.metallib | wc -l | tr -d ' ') 个)..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/FrameworkMetallibs"
    cp "$METALLIBS"/*.metallib "$APP_BUNDLE/Contents/Resources/FrameworkMetallibs/"
fi

# 清扩展属性 (防 codesign 报 "resource fork / Finder information not allowed")
# iCloud Drive 同步范围内的目录会被 fileproviderd 反复写回 xattrs,需要多次重试
find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
xattr -d "com.apple.fileprovider.fpfs#P" "$APP_BUNDLE" 2>/dev/null || true

# 签名 - 优先 Apple Development 证书,fallback ad-hoc
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Apple Development|Developer ID Application/{print $2; exit}')"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔐 使用证书签名: $SIGN_IDENTITY"
    sign_ok=0
    for attempt in 1 2 3; do
        find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
        xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
        xattr -d "com.apple.fileprovider.fpfs#P" "$APP_BUNDLE" 2>/dev/null || true
        if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null; then
            sign_ok=1
            break
        fi
        sleep 0.2
    done
    if [ $sign_ok -eq 0 ]; then
        echo "❌ codesign 失败 (iCloud daemon 反复写回 xattr?)"
        exit 1
    fi
    echo "✅ 签名稳定,TCC 权限不会因为重 build 丢失"
else
    echo "🔐 未找到 Apple Development 证书,退回 ad-hoc 签名"
    echo "   ⚠️  每次重 build 后 CDHash 变,可能需要重新授权 Accessibility/截屏"
    echo "   💡 免费配置 (5 分钟,任意 Apple ID 即可,不需付费 \$99 Developer Program):"
    echo "      详见 docs/signing-and-install.md"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "✅ 构建完成: $APP_BUNDLE"
echo ""
echo "  双击 $APP_NAME.app 即可启动"
echo "  或者运行: open $APP_NAME.app"
echo "  日常开发建议: ./install.sh (覆盖装到 /Applications + 自动启动)"
