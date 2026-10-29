import Foundation
import AppKit
import Vision
import CoreGraphics
import ScreenCaptureKit
import Carbon
import ApplicationServices

// MARK: - 全局配置

enum Config {
    /// 全局快捷键：默认 Command + Shift + E（⌘⇧E）
    ///
    /// 刻意**不使用 Option 键**：Option+Q 是 macOS 常用输入键（œ），
    /// 只带 Option 的组合会和用户的日常打字冲突。⌘⇧E 无系统级占用。
    /// 修改方式：改 `~/Applications/hotkey.json`（见 set-hotkey.py），
    /// 或改本文件后重新编译。
    static var hotKeyKeyCode: UInt16 = 14 // E（keyCode 14）
    static var hotKeyModifiers: NSEvent.ModifierFlags = [.command, .shift]
    static var hotKeyDisplay = "⌘⇧E"

    /// Carbon 的修饰键位掩码 —— 与 Cocoa 的 NSEvent.ModifierFlags.rawValue **完全不同**。
    ///
    /// Cocoa 的 rawValue 是高位布局（⌘=0x100000、⇧=0x020000），
    /// 而 Carbon 用的是低位：cmdKey=256、shiftKey=512、optionKey=2048、controlKey=4096。
    /// 曾误把 Cocoa rawValue 传给 RegisterEventHotKey，导致热键实际注册为一个
    /// 永不触发的组合，表现就是「按了完全没反应」。切勿改回 rawValue。
    static var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if hotKeyModifiers.contains(.command) { result |= UInt32(cmdKey) }
        if hotKeyModifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if hotKeyModifiers.contains(.option) { result |= UInt32(optionKey) }
        if hotKeyModifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    /// 用户自定义快捷键配置文件（安装目录下的 hotkey.json）
    private static var hotKeyConfigURL: URL? {
        // 优先读安装目录旁的配置，其次读 app bundle 内的默认配置
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("hotkey.json"),
            Bundle.main.url(forResource: "hotkey", withExtension: "json"),
        ]
        for url in candidates {
            if let url, FileManager.default.isReadableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// 载入用户自定义快捷键；若配置非法则回退默认值
    static func loadHotKey() {
        guard let url = hotKeyConfigURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hotkey = json["hotkey"] as? [String: Any],
              let keyCode = hotkey["keyCode"] as? Int,
              let modifierNames = hotkey["modifiers"] as? [String]
        else { return }

        var flags: NSEvent.ModifierFlags = []
        for name in modifierNames {
            switch name {
            case "command": flags.insert(.command)
            case "control": flags.insert(.control)
            case "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "function": flags.insert(.function)
            default: break
            }
        }
        // 至少要有一个修饰键，且不能只有 option（避免与打字冲突）
        guard !flags.isEmpty, flags != [.option] else {
            log("hotkey.json 修饰键无效（仅 option 会与打字冲突），已忽略")
            return
        }
        hotKeyKeyCode = UInt16(keyCode)
        hotKeyModifiers = flags
        hotKeyDisplay = hotkey["display"] as? String ?? hotKeyDisplay
        log("loaded custom hotkey: \(hotKeyDisplay)")
    }

    static var supportDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuCiShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var resultFile: URL { supportDir.appendingPathComponent("last-result.json") }
    static var handshakeFile: URL { supportDir.appendingPathComponent("handshake.json") }
    static var logFile: URL { supportDir.appendingPathComponent("qucishot.log") }

    static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let fh = FileHandle(forWritingAtPath: logFile.path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 识别结果

struct OcrResult {
    var text: String
    var confidence: Double
    var candidates: [String]
    var timestamp: Double

    var json: [String: Any] {
        [
            "text": text,
            "confidence": confidence,
            "candidates": candidates,
            "timestamp": timestamp
        ]
    }
}

// MARK: - OCR 引擎

enum OCREngine {
    /// 多策略尝试，取置信度最高的非空结果。
    /// 生僻字要点：关闭语言纠正时 Vision 更倾向于保留原字形，所以两种模式都要跑。
    static func recognize(in image: CGImage) -> OcrResult? {
        let attempts: [(langs: [String], correct: Bool, upscale: CGFloat)] = [
            (["zh-Hans", "zh-Hant", "en-US"], true,  1.0),
            (["zh-Hans", "zh-Hant", "en-US"], false, 1.0),
            (["zh-Hant", "zh-Hans"],           false, 1.0),
            (["zh-Hans"],                     true,  2.0),
            (["zh-Hans"],                     false, 2.0),
            (["zh-Hant"],                     false, 2.0),
        ]

        var best: OcrResult?

        for attempt in attempts {
            let target: CGImage
            if attempt.upscale == 1.0 {
                target = image
            } else if let scaled = upscale(image, by: attempt.upscale) {
                target = scaled
            } else {
                continue
            }

            guard let single = run(target, langs: attempt.langs, correct: attempt.correct) else { continue }
            let result = OcrResult(text: single.text,
                                   confidence: single.confidence,
                                   candidates: single.candidates,
                                   timestamp: Date().timeIntervalSince1970)
            Config.log("OCR langs=\(attempt.langs) correct=\(attempt.correct) up=\(attempt.upscale) -> '\(result.text)' conf=\(String(format: "%.2f", result.confidence))")
            if result.text.isEmpty { continue }
            if best == nil || result.confidence > best!.confidence { best = result }
            if result.confidence > 0.88 { break }
        }
        return best
    }

    private static func run(_ image: CGImage, langs: [String], correct: Bool)
        -> (text: String, confidence: Double, candidates: [String])? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correct
        request.recognitionLanguages = langs
        request.minimumTextHeight = 0.005
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            Config.log("OCR error: \(error.localizedDescription)")
            return nil
        }

        let observations = request.results ?? []
        guard !observations.isEmpty else { return nil }

        // 视觉行排序：从上到下，同行从左到右
        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.012 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var pieces: [String] = []
        var candidates: [String] = []
        var confidences: [Double] = []
        var lastBottom: CGFloat?

        for observation in sorted {
            guard let top = observation.topCandidates(3).first else { continue }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let bottom = lastBottom, bottom - observation.boundingBox.minY > 0.008 {
                pieces.append("\n")
            }
            pieces.append(text)
            confidences.append(Double(top.confidence))
            for c in observation.topCandidates(3) where c.string != text {
                candidates.append(c.string)
            }
            lastBottom = observation.boundingBox.minY
        }

        let joined = pieces.joined()
        let avg = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return (joined, avg, candidates)
    }

    private static func upscale(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard width > 0, height > 0, width < 8000, height < 8000 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

// MARK: - 旧版屏幕抓取回退

/// macOS 15 起 CGWindowListCreateImage 已被废弃，但仍是可靠的回退路径。
/// 通过动态方式调用，避免在编译期触发 unavailable 错误。
enum LegacyScreenCapture {
    typealias CaptureFn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

    static let capture: ((CGRect) -> CGImage?)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        typealias Fn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        let fn = unsafeBitCast(symbol, to: Fn.self)
        return { rect in
            fn(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming])?.takeRetainedValue()
        }
    }()
}

// MARK: - 全屏遮罩层（跨屏框选）

@MainActor
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 框选遮罩层

@MainActor
final class SelectionOverlay: NSObject {
    private var windows: [OverlayWindow] = []
    private var screens: [NSScreen] = []
    /// 每块屏幕各自的冻结画面（与 screens 一一对应）
    private var frozenImages: [CGImage?] = []

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var isSelecting = false
    private var didComplete = false
    /// 拖框轮询定时器：窗口是 nonactivating，鼠标事件经常不派发，
    /// 直接轮询全局鼠标按键状态与位置，任何情况下都可靠
    private var dragTimer: Timer?
    private var lastButtonPressed = false

    var onFinish: ((CGRect, CGImage) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: 绘制层

    @MainActor
    private final class OverlayView: NSView {
        /// 明确使用左下原点坐标系，与 AppKit 屏幕坐标 / 鼠标坐标保持一致
        override var isFlipped: Bool { false }

        var selectionRect: NSRect = .zero
        var hasSelection = false
        var snapshot: CGImage?
        /// 该屏冻结画面对应的屏幕尺寸（点）
        var screenSize: NSSize = .zero

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            // 不做全屏压暗：只有选区之外变暗，这样框选时能看清原字（生僻字尤其需要）
            if hasSelection {
                let rect = selectionRect
                ctx.saveGState()
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
                ctx.addPath(CGPath(rect: bounds, transform: nil))
                ctx.addPath(CGPath(rect: rect, transform: nil))
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()

                ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
            }

            drawLoupe(ctx: ctx)
        }

        private func drawLabel(_ text: String, at point: NSPoint, ctx: CGContext) {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white
            ])
            let size = attributed.size()
            let box = NSRect(x: point.x, y: point.y, width: size.width + 14, height: size.height + 8)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            attributed.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4))
        }

        /// 跟随鼠标的放大镜
        private func drawLoupe(ctx: CGContext) {
            guard let snapshot, let window else { return }
            let mouse = window.mouseLocationOutsideOfEventStream
            let loupe: CGFloat = 150
            let zoom: CGFloat = 3.0

            var origin = NSPoint(x: mouse.x + 22, y: mouse.y + 22)
            if origin.x + loupe > bounds.maxX { origin.x = mouse.x - loupe - 22 }
            if origin.y + loupe > bounds.maxY { origin.y = mouse.y - loupe - 22 }
            let rect = NSRect(origin: origin, size: NSSize(width: loupe, height: loupe))

            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.clip()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect)

            // 快照是像素坐标（Retina 2x），视图是点坐标；Y 轴需翻转
            let scaleX = CGFloat(snapshot.width) / max(screenSize.width, 1)
            let scaleY = CGFloat(snapshot.height) / max(screenSize.height, 1)
            let sampleSize = NSSize(width: loupe / zoom, height: loupe / zoom)
            let sampleRect = NSRect(x: mouse.x - sampleSize.width / 2,
                                    y: mouse.y - sampleSize.height / 2,
                                    width: sampleSize.width, height: sampleSize.height)
            // AppKit 坐标（原点在左下）→ 图像坐标（原点在左上）：翻转 Y
            let cgRect = CGRect(x: sampleRect.minX * scaleX,
                                y: (screenSize.height - sampleRect.maxY) * scaleY,
                                width: sampleRect.width * scaleX,
                                height: sampleRect.height * scaleY)
            if let cropped = snapshot.cropping(to: cgRect) {
                ctx.interpolationQuality = .none
                ctx.draw(cropped, in: rect)
            }
            ctx.restoreGState()

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect.insetBy(dx: 1, dy: 1))
        }
    }

    // MARK: 生命周期

    func start() async {
        screens = NSScreen.screens

        // 先冻结画面（用 SCK，避免废弃 API），再显示遮罩
        let captured = await SelectionOverlay.captureAllScreens()
        frozenImages = screens.map { screen in
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return captured[CGDirectDisplayID(id.uint32Value)]
            }
            return nil
        }
        if captured.isEmpty {
            // SCK 失败时回退旧 API
            frozenImages = screens.map { capture(screen: $0) }
        }

        for (index, screen) in screens.enumerated() {
            let frame = screen.frame
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
            view.snapshot = frozenImages[index]
            view.screenSize = frame.size

            let window = OverlayWindow(contentRect: frame,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
            window.contentView = view
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            windows.append(window)
            window.orderFrontRegardless()
        }

        // 让第一个窗口成为 key，这样鼠标事件走本地监听（不需要辅助功能权限）
        windows.first?.makeKey()

        Config.log("overlay started, screens=\(screens.count), frozen=\(frozenImages.compactMap { $0 }.count)")

        // 鼠标事件不依赖系统派发，直接轮询全局按键状态
        startMousePolling()
    }

    // MARK: 事件（轮询方案）

    // 不再依赖系统把鼠标事件派发给窗口（nonactivating 窗口 + accessory 应用
    // 经常收不到 down/dragged/up），改为 120Hz 轮询全局鼠标按键状态与位置，
    // 按下沿开始选区、按住期间更新、松开沿收尾。任何窗口状态下都可靠。

    private func startMousePolling() {
        stopDragTimer()
        lastButtonPressed = (NSEvent.pressedMouseButtons & 1) != 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // 注意：Timer 回调虽在主线程，但不在 MainActor 上下文里，
            // 直接 assumeIsolated 会触发运行时断言崩溃（已踩过，SIGTRAP）。
            // 必须用 Task 跳到 MainActor。
            Task { @MainActor in self?.pollMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func stopDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func pollMouse() {
        guard !didComplete else { return }
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0
        let now = NSEvent.mouseLocation

        if pressed, !lastButtonPressed, !isSelecting {
            // 按下沿：开始选区
            isSelecting = true
            startPoint = now
            currentRect = NSRect(origin: now, size: .zero)
            Config.log("selection begin at (\(Int(now.x)), \(Int(now.y)))")
        } else if pressed, isSelecting, let start = startPoint {
            // 按住拖动：更新选区
            currentRect = NSRect(x: min(start.x, now.x), y: min(start.y, now.y),
                                 width: abs(now.x - start.x), height: abs(now.y - start.y))
            updateSelection()
        } else if !pressed, lastButtonPressed, isSelecting {
            // 松开沿：收尾
            Config.log("selection end, w=\(Int(currentRect.width)), h=\(Int(currentRect.height))")
            finishSelection()
        }
        lastButtonPressed = pressed
    }

    private func finishSelection() {
        isSelecting = false
        didComplete = true
        let rect = currentRect

        guard rect.width > 4, rect.height > 4 else {
            Config.log("selection too small -> cancel (w=\(rect.width), h=\(rect.height))")
            teardown()
            onCancel?()
            return
        }
        // 关键：必须在 teardown() 之前裁剪 —— teardown 会清空 frozenImages，
        // 先拆后裁会因数组越界直接 SIGTRAP 崩溃（已踩过）。
        guard let cropped = crop(rect: rect) else {
            Config.log("crop failed -> cancel")
            teardown()
            onCancel?()
            return
        }
        teardown()
        onFinish?(rect, cropped)
    }

    func handleEscape() {
        teardown()
        onCancel?()
    }

    private func updateSelection() {
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView as? OverlayView, index < screens.count else { continue }
            let frame = screens[index].frame
            let local = NSRect(x: currentRect.minX - frame.minX,
                               y: currentRect.minY - frame.minY,
                               width: currentRect.width, height: currentRect.height)
            let belongs = NSPointInRect(NSPoint(x: currentRect.midX, y: currentRect.midY), frame)
            view.selectionRect = local
            view.hasSelection = belongs
            view.needsDisplay = true
        }
    }

    /// 从选区所在屏幕的快照中裁剪
    ///
    /// 坐标系换算（关键）：
    /// - 鼠标坐标 `rect` 用的是 AppKit 屏幕坐标系，原点在**左下**，Y 轴向上
    /// - CGImage 裁剪原点也在**左下**（Core Graphics 图像坐标），Y 轴向上
    ///   但 `CGImage.cropping(to:)` 的矩形按 Core Graphics 图像空间解释，
    ///   其中 y=0 对应图像**顶部**行 —— 因此必须翻转 Y。
    private func crop(rect: NSRect) -> CGImage? {
        let mid = NSPoint(x: rect.midX, y: rect.midY)
        guard let index = screens.firstIndex(where: { NSPointInRect(mid, $0.frame) }) else { return nil }
        let frame = screens[index].frame
        guard let image = frozenImages[index] else { return nil }
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height

        // Y 翻转：AppKit 的 maxY 对应图像的顶部
        let cgRect = CGRect(x: (rect.minX - frame.minX) * scaleX,
                            y: (frame.maxY - rect.maxY) * scaleY,
                            width: rect.width * scaleX,
                            height: rect.height * scaleY).standardized
        guard cgRect.width >= 1, cgRect.height >= 1 else { return nil }
        return image.cropping(to: cgRect)
    }

    private func teardown() {
        stopDragTimer()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        frozenImages.removeAll()
        NSCursor.arrow.set()
    }

    /// 冻结单块屏幕画面（回退路径：SCK 不可用时使用旧 API）
    private func capture(screen: NSScreen) -> CGImage? {
        guard let fn = LegacyScreenCapture.capture else { return nil }
        return fn(screen.frame)
    }

    /// 取某块屏幕的 Retina 倍率
    private static func screenScale(for displayID: CGDirectDisplayID) -> Double {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(number.uint32Value) == displayID {
                return Double(screen.backingScaleFactor)
            }
        }
        return 2.0
    }

    /// 用 ScreenCaptureKit 抓取全部屏幕画面，按显示器 ID 返回（key: CGDirectDisplayID）
    static func captureAllScreens() async -> [CGDirectDisplayID: CGImage] {
        guard CGPreflightScreenCaptureAccess() else {
            Config.log("screen capture permission NOT granted")
            return [:]
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var images: [CGDirectDisplayID: CGImage] = [:]
            for display in content.displays {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                // 关键：SCK 默认输出被降采样（实测 1920x1080），
                // 必须显式指定原生像素倍率，否则 PDF 小字识别率会大幅下降。
                let scale = screenScale(for: display.displayID)
                config.width = Int(Double(display.width) * scale)
                config.height = Int(Double(display.height) * scale)
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    images[display.displayID] = image
                }
            }
            Config.log("SCK captured \(images.count) display(s)")
            return images
        } catch {
            Config.log("SCK capture error: \(error.localizedDescription)")
            return [:]
        }
    }
}

// MARK: - 结果提示（仅失败时出现，成功路径完全静默）

@MainActor
final class ResultToast: NSObject {
    private var window: NSWindow?
    private var dismissTimer: Timer?

    /// 识别失败时的极简提示 —— 必须让用户知道"没复制成功"
    func showFailure(near point: NSPoint) {
        show(text: "没识别到文字", detail: "换个位置再框一次", near: point)
    }

    /// 缺少屏幕录制权限时，在按下快捷键的地方给出明确指引
    func showScreenCaptureNeeded(near point: NSPoint) {
        show(text: "需要「屏幕录制」权限",
             detail: "已帮你打开设置，列表里打开取词助手开关（没有就点+号添加）后重开本 App",
             near: point)
    }

    /// 屏幕录制已在设置里授权，但必须重启一次 app 才生效
    func showScreenCaptureGranted() {
        let center = NSEvent.mouseLocation
        show(text: "屏幕录制已授权 ✅",
             detail: "请退出取词助手并重新打开一次，截图即可生效",
             near: center)
    }

    /// 保留的成功提示（仅在落盘失败等异常时使用）
    func show(text: String, confidence: Double, near point: NSPoint) {
        let detail = String(format: "已复制 · %.0f%%", confidence * 100)
        show(text: text, detail: detail, near: point)
    }

    private func show(text: String, detail: String, near point: NSPoint) {
        dismissTimer?.invalidate()
        window?.orderOut(nil)

        let headline = NSTextField(labelWithString: text)
        headline.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 2
        headline.preferredMaxLayoutWidth = 260

        let caption = NSTextField(labelWithString: detail)
        caption.font = NSFont.systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [headline, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.blendingMode = .behindWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.masksToBounds = true
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])

        let fitting = stack.fittingSize
        let width = min(280, max(140, fitting.width))
        let height = fitting.height

        var origin = NSPoint(x: point.x - width / 2, y: point.y - height - 10)
        if origin.y < 40 { origin.y = point.y + 18 }
        if let screen = NSScreen.screens.first {
            origin.x = min(max(8, origin.x), screen.frame.maxX - width - 8)
            origin.y = min(max(8, origin.y), screen.frame.maxY - height - 8)
        }

        let win = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        win.contentView = panel
        win.level = .statusBar
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.orderFrontRegardless()
        window = win

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.orderOut(nil)
            }
        }
    }
}

// MARK: - 权限指引弹窗

/// 权限指引弹窗 —— 由 AppDelegate 自动触发，也可用 `qucishot --guide` 手动调出。
///
/// 说明两件容易卡住的事：
/// 1. 必须在列表里把开关**打开**，仅仅打开设置窗口没有用；
/// 2. 本程序重新编译后代码签名哈希会变，TCC 里旧的授权就失效了
///    （系统设置里看着是开着的，API 却说没授权），此时需要**关掉再重新打开**刷新记录。
@MainActor
func showPermissionGuideAlert() {
    let accessibilityOK = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
    let screenOK = CGPreflightScreenCaptureAccess()

    let alert = NSAlert()
    alert.messageText = "取词助手 · 权限状态"
    var body = """
    当前快捷键：\(Config.hotKeyDisplay)

    \(screenOK ? "✅" : "❌") 屏幕录制 —— 缺少它无法截取画面（必需）
    \(accessibilityOK ? "✅" : "⚠️") 辅助功能 —— 缺少它快捷键可能被其它软件抢走

    开启方法：系统设置 → 隐私与安全性 → 分别进入「屏幕录制」和「辅助功能」，
    找到「取词助手」把开关打开（变蓝）。
    """
    if !screenOK {
        body += """

        ⚠️ 如果「屏幕录制」列表里没有「取词助手」：点列表下方的「+」号，
        手动选择  ~/Applications/QuCiShot.app  添加进去，再把开关打开。
        （后台类 App 不会自动出现在列表里，必须手动加。）

        另外：打开开关后，请**退出取词助手并重新打开一次**，屏幕录制才会真正生效。
        """
    }
    alert.informativeText = body
    alert.alertStyle = screenOK ? .informational : .warning
    alert.addButton(withTitle: "打开系统设置")
    alert.addButton(withTitle: "知道了")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 应用主体

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 全局唯一实例（Carbon 热键回调是 C 闭包，需要静态访问）
    static weak var shared: AppDelegate?

    private(set) var overlay: SelectionOverlay?
    private let toast = ResultToast()
    private var isBusy = false
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }

        // .accessory = 无 Dock 图标、不抢焦点；但保留菜单栏小图标方便操作
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        Config.loadHotKey()
        registerHotKey()
        writeHandshake()
        Config.log("QuCiShot launched. hotkey=\(Config.hotKeyDisplay)")

        requestScreenCaptureIfNeeded()

        // 本地监听只负责 Esc 取消；鼠标按下/拖动/松手由 overlay 内部的
        // 全局轮询处理（nonactivating 窗口经常收不到鼠标事件，轮询才可靠）
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let overlay = self.overlay else { return event }
            if event.keyCode == 53 { overlay.handleEscape(); return nil }
            return event
        }
    }

    // MARK: 菜单栏图标（和晾衣绳一样挂在屏幕右上角，不进程序坞）

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 彩色圆角小图标：蓝色底 + 白色「取」，在菜单栏里一眼可见
            let size = NSSize(width: 18, height: 18)
            let img = NSImage(size: size, flipped: false) { rect in
                let inset = rect.insetBy(dx: 0.5, dy: 0.5)
                let path = NSBezierPath(roundedRect: inset, xRadius: 4.5, yRadius: 4.5)
                // 蓝色渐变底
                if let gradient = NSGradient(colors: [
                    NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.95, alpha: 1),
                    NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.85, alpha: 1)
                ]) {
                    gradient.draw(in: path, angle: -90)
                } else {
                    NSColor.systemBlue.setFill()
                    path.fill()
                }
                // 白色「取」字
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 11.5),
                    .foregroundColor: NSColor.white
                ]
                let str = NSAttributedString(string: "取", attributes: attrs)
                let strSize = str.size()
                str.draw(at: NSPoint(x: (rect.width - strSize.width) / 2,
                                     y: (rect.height - strSize.height) / 2))
                return true
            }
            img.isTemplate = false   // 保持彩色，不随系统变单色
            button.image = img
            button.toolTip = "取词助手 · \(Config.hotKeyDisplay) 框选识别"
        }

        let menu = NSMenu()

        let usage = NSMenuItem(title: "按 \(Config.hotKeyDisplay)，拖框圈字，松手即入剪贴板", action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)
        menu.addItem(.separator())

        let status = NSMenuItem(title: "权限状态与设置…", action: #selector(statusItemShowGuide), keyEquivalent: "")
        status.target = self
        menu.addItem(status)

        let reopen = NSMenuItem(title: "重启取词助手", action: #selector(statusItemRestart), keyEquivalent: "")
        reopen.target = self
        menu.addItem(reopen)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出取词助手", action: #selector(statusItemQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        Config.log("menu bar status item installed")
    }

    @objc private func statusItemShowGuide() {
        showPermissionGuideAlert()
    }

    @objc private func statusItemRestart() {
        let appURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 等当前进程退出后再重新打开
        task.arguments = ["-c", "sleep 1; open \"\(appURL.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func statusItemQuit() {
        Config.log("quit from menu bar")
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: Config.handshakeFile)    }

    // MARK: 全局快捷键

    // MARK: 全局快捷键 —— 双轨方案

    /// 轨道 1：Carbon RegisterEventHotKey（无需权限，但可能被前台 app 的菜单快捷键拦截）
    /// 轨道 2：NSEvent.addGlobalMonitorForEvents（在菜单之前捕获，需要辅助功能权限，不会被拦截）
    private func registerHotKey() {
        registerCarbonHotKey()
        installGlobalKeyMonitor()
    }

    /// Carbon 全局热键 —— 无权限要求，作为降级方案
    private func registerCarbonHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5143_5543), id: 1) // "QCUC"
        let keyCode = UInt32(Config.hotKeyKeyCode)
        let modifiers = Config.carbonModifiers
        var ref: EventHotKeyRef?
        // 用 GetEventDispatcherTarget()：本 app 是 .accessory（无 Dock / 无菜单栏），
        // 走 application target 时 Carbon 事件不一定能派发到。
        let status = RegisterEventHotKey(keyCode, modifiers,
                                         hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            Config.log("Carbon RegisterEventHotKey failed: \(status)")
            return
        }
        Config.log("Carbon hotkey registered: \(Config.hotKeyDisplay) mods=\(modifiers) keyCode=\(keyCode)")

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            guard kind == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
            var firedID = EventHotKeyID()
            let result = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &firedID)
            if result == noErr {
                DispatchQueue.main.async {
                    AppDelegate.shared?.triggerCapture()
                }
            }
            return noErr
        }
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), handler, 1, &eventType, nil, &handlerRef)
        if installStatus != noErr {
            Config.log("InstallEventHandler failed: \(installStatus)")
        }
    }

    /// NSEvent 全局监听 —— 在菜单系统之前捕获按键，不会被任何 app 拦截
    private var globalKeyMonitor: Any?

    private func installGlobalKeyMonitor() {
        // 移除旧的
        if let old = globalKeyMonitor {
            NSEvent.removeMonitor(old)
            globalKeyMonitor = nil
        }

        // 检查辅助功能权限（NSEvent 全局监听需要它）
        // prompt: true 才会把本 app 登记进「辅助功能」列表并弹系统授权框。
        // 传 nil 只是静默查询，app 永远不会出现在列表里，用户也就无从勾选。
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Config.log("accessibility permission: \(trusted ? "granted" : "not granted")")
        if !trusted {
            Config.log("fallback: 仅使用 Carbon 热键（可能受前台 app 菜单拦截）")
            showPermissionGuide()
            startAccessibilityPolling()
            return
        }

        let keyCode = Config.hotKeyKeyCode
        let modifiers = Config.hotKeyModifiers

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == keyCode,
                  event.modifierFlags.intersection([.deviceIndependentFlagsMask]) == modifiers
            else { return }
            DispatchQueue.main.async {
                AppDelegate.shared?.triggerCapture()
            }
        }
        Config.log("NSEvent global monitor installed for \(Config.hotKeyDisplay)")
    }

    // MARK: 单实例保护

    /// 只允许一个实例运行。
    ///
    /// 必须有这个保护：LaunchAgent 配了 KeepAlive，一旦进程被信号杀掉 launchd 会立刻
    /// 重新拉起；若启动时不检查已有实例，就会同时跑好几个，导致
    /// RegisterEventHotKey 相互覆盖、且一次按键弹出多个选区框。
    /// 另外桌面副本与 ~/Applications 副本的 bundle id 相同，也靠这里收敛成一个。
    private func ensureSingleInstance() -> Bool {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "com.qucishot"
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleId && $0.processIdentifier != myPid
        }
        guard others.isEmpty else {
            Config.log("another instance already running: \(others.map { $0.processIdentifier }) -> exit")
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    // MARK: 权限引导

    /// 屏幕录制权限处理。
    ///
    /// 关键坑：本 app 是后台 `.accessory` 应用，`CGRequestScreenCaptureAccess()`
    /// 在后台态常常**弹不出系统授权框**，于是 app 不会被登记进「屏幕录制」列表，
    /// 用户在设置里既找不到它、勾了系统也不认。
    ///
    /// 因此这里不依赖系统弹框，而是**直接打开设置页 + 弹窗指引**：
    /// 让用户手动在列表里找到「取词助手」打开开关；若列表里没有，就用左下角
    /// 的「+」号把 ~/Applications/取词助手.app 加进去。
    ///
    /// 另外 macOS 要求：授予屏幕录制后必须**退出并重开 app** 才真正生效，
    /// 所以授权后由轮询逻辑提示用户重启一次（见 startScreenCapturePolling）。
    private func requestScreenCaptureIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else {
            Config.log("screen capture permission: granted")
            return
        }
        Config.log("screen capture permission MISSING -> 打开设置页并弹窗指引")
        // 直接把用户带到屏幕录制设置页
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        showPermissionGuide()
        startScreenCapturePolling()
    }

    private var screenCaptureTimer: Timer?
    private var didNotifyScreenCaptureGranted = false

    /// 轮询屏幕录制授权：用户授权后，提示"请重启一次 app"才生效。
    private func startScreenCapturePolling() {
        screenCaptureTimer?.invalidate()
        screenCaptureTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard CGPreflightScreenCaptureAccess() else { return }
            timer.invalidate()
            self.screenCaptureTimer = nil
            Config.log("screen capture permission: granted (polled)")
            guard !self.didNotifyScreenCaptureGranted else { return }
            self.didNotifyScreenCaptureGranted = true
            // 屏幕录制授权后必须重启 app 才生效，明确告诉用户
            DispatchQueue.main.async {
                self.toast.showScreenCaptureGranted()
            }
        }
    }

    private var accessibilityTimer: Timer?

    /// 每 1.5s 复查一次授权状态，一旦用户在系统设置里打开开关就立刻装上监听。
    /// 这样用户不必重启本 app。
    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // 静默查询，不再重复弹系统框
            let query = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
            guard AXIsProcessTrustedWithOptions(query) else { return }
            timer.invalidate()
            self.accessibilityTimer = nil
            Config.log("accessibility granted -> installing NSEvent monitor")
            self.installGlobalKeyMonitor()
        }
    }

    /// 合并的权限指引。
    ///
    /// 重点说明两件事，否则用户很容易卡住：
    /// 1. 必须在列表里把开关**打开**，仅仅打开设置窗口没有用；
    /// 2. 本 app 用 ad-hoc 之外的固定签名前，重新编译会让已授予的权限失效
    ///    （列表里看着是开着的，系统却认为没授权），此时需要**关掉再重新打开**刷新记录。
    private var didShowPermissionGuide = false

    private func showPermissionGuide() {
        guard !didShowPermissionGuide else { return }
        didShowPermissionGuide = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showPermissionGuideAlert()
        }
    }

    private func writeHandshake() {
        let info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "hotkey": Config.hotKeyDisplay,
            "startedAt": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) {
            try? data.write(to: Config.handshakeFile, options: .atomic)
        }
    }

    // MARK: 流程

    @objc private func triggerCapture() {
        Config.log("HOTKEY FIRED")
        guard !isBusy, overlay == nil else { return }

        // 前置检查：没有屏幕录制权限时，直接提示并打开设置，
        // 避免用户框完选区才看到误导性的"没识别到文字"。
        guard CGPreflightScreenCaptureAccess() else {
            Config.log("HOTKEY FIRED but screen capture NOT granted -> guide user")
            toast.showScreenCaptureNeeded(near: NSEvent.mouseLocation)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        isBusy = true
        NSCursor.crosshair.set()

        let overlay = SelectionOverlay()
        self.overlay = overlay
        overlay.onFinish = { [weak self] rect, image in
            self?.performOCR(image, region: rect)
        }
        overlay.onCancel = { [weak self] in
            self?.isBusy = false
            self?.overlay = nil
            NSCursor.arrow.set()
            Config.log("capture cancelled")
        }
        Task { @MainActor in
            await overlay.start()
        }
    }

    private func performOCR(_ image: CGImage, region: NSRect) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OCREngine.recognize(in: image)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.overlay = nil
                NSCursor.arrow.set()

                // 静默写入剪贴板 —— 不弹窗、不通知、不留痕迹
                if let result, !result.text.isEmpty {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result.text, forType: .string)
                    Config.log("clipboard <- \(result.text)")

                    // 仅在落盘失败这种异常情况下提示，正常流程零打扰
                    if !self.writeResultFile(result) {
                        self.toast.show(text: result.text, confidence: result.confidence,
                                       near: NSPoint(x: region.midX, y: region.maxY))
                    }
                } else {
                    Config.log("OCR returned nothing")
                    // 识别失败要告知用户（否则会以为复制成功了）
                    self.toast.showFailure(near: NSPoint(x: region.midX, y: region.maxY))
                }
            }
        }
    }

    /// 记录最近一次识别结果（仅本地文件，不做任何外发）
    private func writeResultFile(_ result: OcrResult) -> Bool {
        var payload = result.json
        payload["clipboard"] = result.text
        payload["app"] = "QuCiShot"
        payload["hotkey"] = Config.hotKeyDisplay
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try data.write(to: Config.resultFile, options: .atomic)
            return true
        } catch {
            Config.log("result file write failed: \(error.localizedDescription)")
            return false
        }
    }

}

// MARK: - 入口

@main
final class QuCiShotMain {
    static func main() {
        // 命令行模式：--check-permission 用于安装脚本自检
        if CommandLine.arguments.contains("--check-permission") {
            let granted = CGPreflightScreenCaptureAccess()
            print(granted ? "granted" : "denied")
            exit(granted ? 0 : 1)
        }
        if CommandLine.arguments.contains("--version") {
            Config.loadHotKey()
            print("QuCiShot 1.0.0  hotkey=\(Config.hotKeyDisplay)")
            exit(0)
        }
        // --guide：手动弹出权限状态窗口（不必重启常驻进程，也不打扰它）
        if CommandLine.arguments.contains("--guide") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Config.loadHotKey()
            DispatchQueue.main.async {
                showPermissionGuideAlert()
                exit(0)
            }
            app.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }
}
