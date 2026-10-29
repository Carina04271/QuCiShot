# 取词助手 (QuCiShot)

一个极简的 macOS 菜单栏小工具：**框选屏幕上的任意文字 → 自动 OCR → 直接进剪贴板 → ⌘V 粘贴纯文字**。

不用打开任何窗口、不用手动截图、不用选区域再点「识别」。按下快捷键，拖一个框，文字就到剪贴板了。
适合从 PDF、图片、视频字幕、不可复制的网页里「抠」文字。

> 菜单栏图标是一个蓝底彩色「取」字；点开有使用说明、权限状态、重启和退出。

---

## ✨ 功能

- 📋 **框选即复制**：⌘⇧E 唤醒 → 拖框 → 松手自动识别并写入剪贴板
- 🔍 **本地 OCR**：基于 Apple Vision 框架，文字识别在本地完成，不上传任何内容
- 🖥️ **菜单栏常驻**：后台运行（不在程序坞显示），开机自启，不干扰工作
- ⌨️ **可改快捷键**：自带 `set-hotkey.py`，一行命令换成你喜欢的组合
- 🪶 **零依赖运行时**：编译后是一个独立的 `.app`，不需要 Python / 任何运行时

---

## 📋 系统要求

- macOS 13 (Ventura) 或更高
- 已安装 **Xcode Command Line Tools**（`xcode-select --install`）
- `python3`（仅构建图标时需要，系统自带）

---

## 🚀 快速开始

```bash
git clone <你的仓库地址> QuCiShot
cd QuCiShot
./install.sh
```

`install.sh` 会：编译 → 安装到 `~/Applications/QuCiShot.app` → 注册开机自启 → 检查权限。
首次会弹窗引导你授予「屏幕录制」权限。

**使用**：在任意界面按 `⌘⇧E` → 拖拽框选要识别的文字 → 松手 → 去别处 `⌘V` 粘贴。

---

## ⌨️ 改快捷键

默认 `⌘⇧E`。想换成别的（例如 `⌘⇧C`）：

```bash
python3 ~/.local/share/qucishot/set-hotkey.py ⌘⇧C
# 或：python3 set-hotkey.py cmd+shift+C
# 查看当前：python3 set-hotkey.py --current
# 列出说明：python3 set-hotkey.py --list
```

改完会自动重启使新快捷键生效。为避免与日常输入冲突，工具会拒绝「只带 Option」的组合（如 ⌥Q 会抢掉 œ）。

---

## ⚠️ 关于「屏幕录制」权限（重要）

macOS 对后台类 App 的屏幕录制授权比较「轴」，请务必照做：

1. 打开 **系统设置 → 隐私与安全性 → 屏幕与系统音频录制**
2. 如果列表里**没有「取词助手」**：点列表下方的 **「+」号**，手动选择 `~/Applications/QuCiShot.app` 添加进去
3. 把开关**打开**
4. **完全退出并重新打开** QuCiShot（菜单栏图标 → 退出，或 `pkill -f QuCiShot.app`，再重开）—— 屏幕录制权限必须重开 App 才生效

> 后台 / 菜单栏 App 不会自动出现在授权列表里，必须手动 `+` 添加，这是系统限制，不是 bug。

### 为什么有时改完代码要重新授权？

默认构建使用 **ad-hoc 签名**，它每次重编都会改变二进制指纹（cdhash），
macOS 会因此让已授予的「屏幕录制」权限失效（系统设置里看着是开着的，API 却返回未授权）。
解决：把开关关掉 → 再打开 → 退出重开 App 一次即可。

如果你有自己的 **Developer ID** 证书，可以用固定身份签名来避免这个问题：

```bash
QUCISHOT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

---

## 🛠 开发者说明

- `./build.sh`：**只**在 `./build/QuCiShot.app` 生成应用，不会动系统目录，方便本地验证。
- `./install.sh`：构建并安装到 `~/Applications`，注册开机自启。
- `./uninstall.sh`：卸载（保留 `~/Library/Application Support/QuCiShot` 运行日志，可手动删）。
- `test_coords.py`：坐标换算一致性测试（AppKit 左下原点 ↔ 图像左上原点 Y 翻转），`python3 test_coords.py` 跑一遍。

---

## 📁 项目结构

```
QuCiShot/
├── Sources/QuCiShot.swift   # 主程序（热键 / 框选 / 截图 / OCR / 剪贴板 / 菜单栏）
├── mkicon.swift             # 生成 icon.png（蓝底「取」字图标）
├── mkicns.py                # 把 png 转成 .icns
├── set-hotkey.py            # 快捷键切换小工具
├── test_coords.py           # 坐标换算测试
├── Resources/
│   ├── icon.png             # 图标源图
│   └── Info.plist           # App 配置（bundle id、权限说明等）
├── build.sh / install.sh / uninstall.sh
└── README.md
```

---

## 📝 已知限制 / 路线图

- 仅支持 macOS（依赖 ScreenCaptureKit / Vision）。
- OCR 语言跟随系统首选语言；多语种混排的识别质量取决于 Vision 框架。
- 欢迎提 Issue / PR：例如自定义识别后动作（翻译、搜索）、多显示器优化等。

---

## 📄 License

[MIT](LICENSE) © QuCiShot contributors
