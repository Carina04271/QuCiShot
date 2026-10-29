#!/bin/bash
# 取词助手（QuCiShot）—— 卸载脚本
set -euo pipefail

APP_NAME="QuCiShot"
BUNDLE_ID="com.qucishot"
AGENT_DIR="$HOME/.local/share/qucishot"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "==> 停止并移除开机自启"
launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
rm -f "$PLIST"
echo "    已移除 $PLIST"

echo "==> 移除应用"
rm -rf "$HOME/Applications/$APP_NAME.app"
echo "    已移除 ~/Applications/$APP_NAME.app"

echo "==> 移除快捷键工具"
rm -rf "$AGENT_DIR"
echo "    已移除 $AGENT_DIR"

echo "==> 保留运行数据（如需彻底清理请手动删除）"
echo "    ~/Library/Application Support/QuCiShot"
echo "    ~/Library/Logs/DiagnosticReports/qucishot-*.ips（崩溃报告，可选）"

echo
echo "✅ 卸载完成"
