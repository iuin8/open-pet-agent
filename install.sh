#!/bin/bash
# install.sh — 一键 build + 覆盖装到 /Applications + 启动
#
# 跟 build.sh 的关系:
#   build.sh        仅构建到 ./OpenPetAgent.app (本地开发版)
#   install.sh   ← 你日常用:./build.sh + 覆盖装到 /Applications + 启动
#
# 用 Apple Development 证书签名时 (build.sh 优先), TCC 权限永久稳定:
# 任意次重 install 后 Accessibility / 截屏 / 麦克风权限都不会丢。
# ad-hoc fallback 时可能要重新授权(详见 build.sh 警告)。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="OpenPetAgent"
SOURCE="$SCRIPT_DIR/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"

# 1. 构建 + 签名
echo "🏗️  构建中..."
./build.sh > /dev/null

# 2. 退出在跑的版本 (无论是从 /Applications 启的还是 .build/.../OpenPetAgent 直跑的)
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "🛑 退出当前运行的 $APP_NAME..."
    pkill -x "$APP_NAME" || true
    # 等进程完全退出避免覆盖时被占用
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
fi

# 3. 覆盖装到 /Applications
echo "📦 安装到 $TARGET..."
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

# 4. 启动新版
echo "🚀 启动新版..."
open "$TARGET"

echo ""
echo "✅ 完成。$APP_NAME 已安装到 /Applications 并启动"
echo ""
SIGN_AUTH="$(codesign -dvvv "$TARGET" 2>&1 | grep 'Authority=Apple Development' | head -1 | sed 's/Authority=//' || true)"
if [ -n "$SIGN_AUTH" ]; then
    echo "   签名身份: $SIGN_AUTH"
    echo "   💡 因签名身份稳定,以后再跑 install.sh 权限不会丢"
else
    echo "   签名身份: ad-hoc (无 Apple Dev 证书 fallback)"
    echo "   ⚠️  ad-hoc 签名可能需要每次重新授权 Accessibility 权限"
fi
