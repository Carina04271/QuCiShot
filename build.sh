#!/bin/bash
# 构建 QuCiShot（取词助手）—— 仅打包成 ./build/QuCiShot.app，不安装到系统目录。
# 安装请另跑 ./install.sh。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP_NAME="QuCiShot"
APP="$BUILD/$APP_NAME.app"
DEVELOPER="/Library/Developer/CommandLineTools"

export DEVELOPER_DIR="$DEVELOPER"

echo "==> 准备构建目录"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
SDK="$(/usr/bin/env -u SDKROOT -u TOOLCHAINS DEVELOPER_DIR="$DEVELOPER" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/env -u SDKROOT -u TOOLCHAINS DEVELOPER_DIR="$DEVELOPER" /usr/bin/xcrun --find swiftc)"
/usr/bin/env -u SDKROOT -u TOOLCHAINS DEVELOPER_DIR="$DEVELOPER" "$SWIFTC" \
  -sdk "$SDK" -parse-as-library -O \
  -framework AppKit -framework Vision -framework ScreenCaptureKit \
  "$ROOT/Sources/QuCiShot.swift" -o "$APP/Contents/MacOS/qucishot"

echo "==> 生成图标"
rm -f "$BUILD/mkicon"
/usr/bin/env -u SDKROOT -u TOOLCHAINS DEVELOPER_DIR="$DEVELOPER" "$SWIFTC" \
  -sdk "$SDK" -O "$ROOT/mkicon.swift" -o "$BUILD/mkicon"
(cd "$ROOT" && "$BUILD/mkicon")
PY="$(command -v python3)"
if [ -z "$PY" ]; then
  echo "❌ 找不到 python3，无法生成图标（icns）"
  exit 1
fi
"$PY" "$ROOT/mkicns.py" "$ROOT/Resources/icon.png" "$APP/Contents/Resources/icon.icns"

echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> 签名"
# 默认 ad-hoc 签名（--sign -）。
# 注意：ad-hoc 每次重编都会产生新的 cdhash，macOS 会让「屏幕录制」等已授予的
# 权限失效（系统设置里看着是开着的，API 却返回未授权）。
# 改完代码后需要：把开关关掉 -> 再打开 -> 退出并重新打开 App 一次。
#
# 若有自己的开发者证书（Developer ID Application），用环境变量指定可避免此问题：
#   QUCISHOT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
if [ -n "${QUCISHOT_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --deep --sign "$QUCISHOT_SIGN_IDENTITY" "$APP"
  echo "    已用指定身份签名：$QUCISHOT_SIGN_IDENTITY"
else
  /usr/bin/codesign --force --deep --sign - "$APP"
  echo "    ⚠️  ad-hoc 签名（重编译会丢失权限授权，见上方说明）"
fi

echo "✅ 完成：仅生成于 $APP"
echo "    安装到 ~/Applications 请运行：./install.sh"
