#!/bin/bash
# 一键构建并组装 dist/LaunchX.app（优先开发证书，回退 ad-hoc 签名）
# 环境开关:
#   LAUNCHX_SKIP_BUILD=1  跳过 swift build（冒烟/调试用）
#   LAUNCHX_DUMMY_BIN=1   二进制缺失时用占位可执行文件继续（仅冒烟）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/LaunchX.app"
# 先在 staging 目录组装/签名，最后用两次 rename 换上新包：
# 不再先 rm -rf 正式路径再慢慢复制——那样在重建的几秒里 dist/LaunchX.app 不存在，
# Finder 若正好打开/刷新旧引用会弹「找不到该文件。」（本地开发时真实踩到过）。
STAGING="$REPO/dist/.LaunchX.app.staging-$$"
OLD="$REPO/dist/.LaunchX.app.old-$$"
CONTENTS="$STAGING/Contents"
BIN="$REPO/.build/release/LaunchX"

cd "$REPO"

cleanup() { rm -rf "$STAGING" "$OLD"; }
trap cleanup EXIT

# 1. release 构建
if [ "${LAUNCHX_SKIP_BUILD:-0}" != "1" ]; then
    swift build -c release
fi

# 2. 二进制
if [ ! -f "$BIN" ]; then
    if [ "${LAUNCHX_DUMMY_BIN:-0}" = "1" ]; then
        mkdir -p "$(dirname "$BIN")"
        printf '#!/bin/sh\nexit 0\n' > "$BIN"
        chmod +x "$BIN"
        echo "⚠️  使用占位二进制（LAUNCHX_DUMMY_BIN=1）"
    else
        echo "❌ 未找到 $BIN，请先 swift build -c release" >&2
        exit 1
    fi
fi

# 3. 在 staging 组装 .app
rm -rf "$STAGING"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/LaunchX"
chmod +x "$CONTENTS/MacOS/LaunchX"
cp "$REPO/resources/Info.plist" "$CONTENTS/Info.plist"

if [ -f "$REPO/resources/AppIcon.icns" ]; then
    cp "$REPO/resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
    echo "⚠️  缺少 resources/AppIcon.icns，继续打包"
fi

# 4. 签名与校验
# 优先使用 Apple Development 证书：TCC（录屏等隐私权限）按代码签名身份匹配，
# ad-hoc 签名的身份就是裸 cdhash，每次重建二进制后旧授权全部失配，导致反复弹权限窗。
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "🔏 使用开发证书签名: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$STAGING"
else
    echo "⚠️  未找到 Apple Development 证书，回退 ad-hoc 签名（每次重建后需重新授予录屏权限）"
    codesign --force --sign - "$STAGING"
fi
codesign --verify --strict "$STAGING" && echo "✅ 签名校验通过"

# 5. 原子换包：正式路径消失的时间只有两次 rename 之间（微秒级），
#    避免 Finder 在重建期间打开旧路径时报「找不到该文件」。
if [ -d "$APP" ]; then
    mv "$APP" "$OLD"
fi
if ! mv "$STAGING" "$APP"; then
    echo "❌ 替换失败，回滚旧包" >&2
    [ -d "$OLD" ] && mv "$OLD" "$APP"
    exit 1
fi
rm -rf "$OLD"
codesign --verify --strict "$APP"

echo "📦 产出: $APP"
