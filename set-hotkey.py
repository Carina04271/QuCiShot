#!/usr/bin/env python3
"""取词助手 —— 快捷键切换工具。

用法：
    set-hotkey.py ⌘⇧E        # 切到 ⌘⇧E（也可写成 cmd+shift+E / Command+Shift+E）
    set-hotkey.py --list      # 列出所有可选组合
    set-hotkey.py --current   # 显示当前快捷键

改完会自动重启取词助手使新快捷键生效。
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
CONFIG = HOME / "Applications/hotkey.json"
BUNDLE_CONFIG = Path("/Applications/QuCiShot.app/Contents/Resources/hotkey.json")
APP = HOME / "Applications/QuCiShot.app"

# 修饰键别名
MOD_ALIASES = {
    "cmd": "command", "command": "command", "⌘": "command",
    "shift": "shift", "⇧": "shift",
    "ctrl": "control", "control": "control", "⌃": "control",
    "opt": "option", "option": "option", "alt": "option", "⌥": "option",
    "fn": "function", "function": "function", "🌐": "function",
}

# 字母/数字 → macOS 虚拟键码
KEYCODES = {
    "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
    "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31,
    "U": 32, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
    "8": 28, "9": 25,
}

SYMBOLS = {
    "⌘": "command", "⇧": "shift", "⌃": "control", "⌥": "option",
}


def parse_hotkey(text: str) -> tuple[list[str], str, str]:
    """把 '⌘⇧E' / 'cmd+shift+E' 解析成 (modifiers, key, display)。"""
    text = text.strip()
    if not text:
        raise ValueError("快捷键不能为空")

    # 归一化：⌘⇧E 这种连续符号写法
    mods: list[str] = []
    key = ""
    for ch in text:
        if ch in SYMBOLS:
            mod = SYMBOLS[ch]
            if mod not in mods:
                mods.append(mod)
        elif ch in "+-_ ":
            continue
        else:
            key = ch.upper()

    # cmd+shift+E 这种带分隔符的写法
    if "+" in text or "-" in text:
        mods = []
        key = ""
        for part in re.split(r"[+\-_ ]+", text):
            if not part:
                continue
            low = part.lower()
            if low in MOD_ALIASES:
                mod = MOD_ALIASES[low]
                if mod not in mods:
                    mods.append(mod)
            else:
                key = part.upper()

    if not key:
        raise ValueError(f"没解析出主键：{text!r}")
    if key not in KEYCODES:
        raise ValueError(f"不支持的主键：{key!r}（支持 A-Z 和 0-9）")

    # 安全约束：只有 option 的组合会与日常打字冲突
    if "option" in mods and len(mods) == 1:
        raise ValueError("拒绝设置：只带 Option 的组合会与日常打字冲突（如 ⌥Q 会抢掉 œ）")

    # macOS 习惯的显示顺序：⌃⌥⇧⌘
    order = [m for m in ("control", "option", "shift", "command", "function") if m in mods]
    display = ""
    for m in order:
        display += {"control": "⌃", "option": "⌥", "shift": "⇧",
                    "command": "⌘", "function": "🌐"}[m]
    display += key
    return order, key, display


def load_config() -> dict:
    for path in (CONFIG, BUNDLE_CONFIG):
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
    return {}


def save_config(config: dict) -> None:
    target = CONFIG if CONFIG.parent.exists() else BUNDLE_CONFIG
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"✅ 已写入 {target}")


def restart_app() -> None:
    subprocess.run(["pkill", "-f", "QuCiShot.app/Contents/MacOS/qucishot"],
                   capture_output=True)
    import time
    time.sleep(1.5)
    if APP.exists():
        subprocess.run(["open", str(APP)], capture_output=True)
        time.sleep(2)
        running = subprocess.run(["pgrep", "-f", "QuCiShot.app/Contents/MacOS/qucishot"],
                                 capture_output=True).returncode == 0
        print("✅ 已重启取词助手" if running else "⚠️  重启失败，请手动打开 QuCiShot.app")
    else:
        print("⚠️  未找到 QuCiShot.app，请手动启动")


def main() -> int:
    parser = argparse.ArgumentParser(description="取词助手快捷键切换")
    parser.add_argument("hotkey", nargs="?", help="新快捷键，如 ⌘⇧E 或 cmd+shift+E")
    parser.add_argument("--list", action="store_true", help="列出可选组合")
    parser.add_argument("--current", action="store_true", help="显示当前快捷键")
    args = parser.parse_args()

    config = load_config()

    if args.list:
        print("可用的 ⌘⇧+单键 组合（全部 26 个字母 + 10 个数字均可用）：")
        alts = config.get("_alternatives", {})
        for name in alts:
            print("   ", name)
        print("\n当前：", config.get("hotkey", {}).get("display", "未知"))
        return 0

    if args.current:
        print("当前快捷键：", config.get("hotkey", {}).get("display", "未知"))
        return 0

    if not args.hotkey:
        parser.print_help()
        return 1

    try:
        mods, key, display = parse_hotkey(args.hotkey)
    except ValueError as exc:
        print(f"❌ {exc}")
        return 1

    config["hotkey"] = {
        "keyCode": KEYCODES[key],
        "modifiers": mods,
        "display": display,
    }
    save_config(config)
    print(f"✅ 快捷键已改为 {display}")
    restart_app()
    return 0


if __name__ == "__main__":
    sys.exit(main())
