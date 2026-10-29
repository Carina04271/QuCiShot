#!/bin/bash
# 取词助手（QuCiShot）—— 安装脚本
#  1) 构建 .app 并安装到 ~/Applications
#  2) 部署快捷键切换工具 set-hotkey.py 到 ~/.local/share/qucishot/
#  3) 注册开机自启（launchd LaunchAgent）
#  4) 检查屏幕录制权限并给出引导
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="QuCiShot"
BUNDLE_ID="com.qucishot"
AGENT_DIR="$HOME/.local/share/qucishot"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_DIR/$BUNDLE_ID.plist"

echo "=========================================="
echo " 取词助手 · 安装"
echo "=========================================="

# ---------- 1. 构建并安装 app ----------
echo
echo "[1/4] 构建应用"
bash "$ROOT/build.sh"

echo
echo "[2/4] 安装到 ~/Applications"
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$ROOT/build/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"
echo "     → $INSTALL_DIR/$APP_NAME.app"

# ---------- 3. 部署快捷键切换工具 ----------
echo
echo "[3/4] 部署快捷键切换工具"
mkdir -p "$AGENT_DIR"
cp "$ROOT/set-hotkey.py" "$AGENT_DIR/set-hotkey.py"
chmod +x "$AGENT_DIR/set-hotkey.py"
echo "     → $AGENT_DIR/set-hotkey.py"
echo "     用法：python3 $AGENT_DIR/set-hotkey.py ⌘⇧E   （改完自动重启生效）"

# ---------- 4. 开机自启 ----------
echo
echo "[4/4] 注册开机自启"
mkdir -p "$LAUNCH_DIR"
# 注意：不要给 AppKit GUI 程序配置 StandardOutPath/StandardErrorPath，
# 否则 launchd 会因日志重定向导致 GUI 崩溃（已在实践中验证）。
rm -f "$PLIST"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert Label -string "$BUNDLE_ID" "$PLIST"
/usr/bin/plutil -insert ProgramArguments -array "$PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$HOME/Applications/$APP_NAME.app/Contents/MacOS/qucishot" "$PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$PLIST"
/usr/bin/plutil -insert KeepAlive -xml '<dict><key>SuccessfulExit</key><false/></dict>' "$PLIST"
/usr/bin/plutil -insert ThrottleInterval -integer 5 "$PLIST"

launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
sleep 1
if launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
    echo "     ✅ 已注册开机自启（$PLIST）"
else
    echo "     ⚠️  自动注册失败（当前环境限制 launchd 域访问）"
    echo "     → 已生成配置文件：$PLIST"
    echo "     → 若登录后未自动启动，请手动添加登录项："
    echo "        系统设置 → 通用 → 登录项 → 添加"
    echo "        $HOME/Applications/$APP_NAME.app"
fi

# ---------- 权限检查 ----------
echo
echo "==> 检查屏幕录制权限"
PERM=$("$HOME/Applications/$APP_NAME.app/Contents/MacOS/qucishot" --check-permission 2>/dev/null || echo "unknown")
if [ "$PERM" = "granted" ]; then
    echo "     ✅ 已获得屏幕录制权限"
else
    echo "     ⚠️  尚未获得「屏幕录制」权限"
    echo "     请到：系统设置 → 隐私与安全性 → 屏幕与系统音频录制"
    echo "     勾选「取词助手」，然后重启该应用"
    echo "     （系统设置里出现「取词助手」才说明它已被识别）"
fi

echo
echo "=========================================="
echo " ✅ 安装完成"
echo "=========================================="
echo
echo "  快捷键：⌘⇧E  (Command + Shift + E)"
echo "  用法  ：在 PDF / 网页 / 图片 / 任意窗口上按 ⌘⇧E → 拖拽框选 → 自动识别并复制"
echo "          ⌘V 即可粘贴识别出的纯文字"
echo
echo "  提示：⌘⇧E 不占用 Option 键，Option+Q 等输入快捷键不受影响"
echo

# 兜底：确保当前有实例在运行
if ! pgrep -f "QuCiShot.app/Contents/MacOS/qucishot" >/dev/null 2>&1; then
    open "$HOME/Applications/$APP_NAME.app"
    sleep 2
    if pgrep -f "QuCiShot.app/Contents/MacOS/qucishot" >/dev/null 2>&1; then
        echo "  ✅ 已启动当前实例"
    else
        echo "  ⚠️  启动失败，请手动双击：$HOME/Applications/$APP_NAME.app"
    fi
fi
echo
echo "  状态检查：pgrep -fl qucishot"
echo "  日志    ：tail -f \"$HOME/Library/Application Support/QuCiShot/qucishot.log\""
echo "  卸载    ：bash \"$ROOT/uninstall.sh\""
echo
