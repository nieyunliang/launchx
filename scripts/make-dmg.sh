#!/bin/bash
# 构建 dist/LaunchX.app 并打成 dist/LaunchX.dmg（带 Applications 软链，支持拖拽安装）
# 环境开关:
#   SKIP_APP_BUILD=1  跳过 build-app.sh（已有 .app 时直接打 DMG）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/LaunchX.app"
DMG="$REPO/dist/LaunchX.dmg"
STAGING="$REPO/dist/.dmg-staging"

cd "$REPO"

# 1. 先确保 .app 存在
if [ "${SKIP_APP_BUILD:-0}" != "1" ]; then
    bash "$REPO/scripts/build-app.sh"
fi
if [ ! -d "$APP" ]; then
    echo "❌ 未找到 $APP，请先运行 scripts/build-app.sh" >&2
    exit 1
fi

# 2. 组装 DMG 暂存目录（.app + /Applications 软链）
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/LaunchX.app"
ln -s /Applications "$STAGING/Applications"

# 3. 打包为压缩只读 DMG（新系统用 diskutil；hdiutil create 在 macOS 27 起已弃用）
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from \
        --volumeName "LaunchX" \
        --format UDZO \
        "$STAGING" "$DMG"
else
    hdiutil create \
        -volname "LaunchX" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG"
fi

rm -rf "$STAGING"

echo "💾 产出: $DMG ($(du -h "$DMG" | cut -f1))"
