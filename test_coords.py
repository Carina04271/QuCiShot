#!/usr/bin/env python3
"""取词助手 —— 坐标换算一致性测试。

背景：
  - 鼠标坐标 (AppKit) 原点在**左下**，Y 轴向上
  - 图像裁剪 (CGImage.cropping) 的矩形按 Core Graphics 图像空间解释，y=0 对应图像**顶部**行

所以从鼠标矩形换算到图像矩形时必须翻转 Y：
    y_image = (screen.maxY - rect.maxY) * scale

这个测试用纯 Python 重现 Swift 侧的换算，并构造一个
「画面上上下颠倒的两个标记」来验证换算方向是否正确。
"""
import sys

SCREEN_W, SCREEN_H = 1470.0, 956.0   # 点坐标
SCALE = 2.0                          # Retina 倍率
IMG_W, IMG_H = SCREEN_W * SCALE, SCREEN_H * SCALE


def appkit_rect_to_image(rect):
    """复现 Swift 侧 crop() 的换算。rect = (x, y, w, h)，AppKit 坐标（左下原点）。"""
    x, y, w, h = rect
    return (
        x * SCALE,
        (SCREEN_H - (y + h)) * SCALE,   # Y 翻转
        w * SCALE,
        h * SCALE,
    )


def image_row_of_point(py):
    """给定 AppKit 点坐标的 y，返回它在图像中的行号（自顶部起）。"""
    return int((SCREEN_H - py) * SCALE)


def main():
    failures = []

    # 用例1：屏幕正中央的选区，图像坐标应在垂直中点
    rect = (700.0, 450.0, 100.0, 50.0)      # 居中
    _, iy, _, ih = appkit_rect_to_image(rect)
    expect_top = (SCREEN_H - 500.0) * SCALE   # 选区上边对应的图像行
    if abs(iy - expect_top) > 0.01:
        failures.append(f"用例1 顶部换算错误: got {iy}, expect {expect_top}")

    # 用例2：靠近屏幕顶部的选区 → 图像 y 应该很小（靠近顶部）
    rect_top = (600.0, 900.0, 200.0, 40.0)   # AppKit y=900..940 靠上
    _, iy_top, _, _ = appkit_rect_to_image(rect_top)
    if iy_top > 200:
        failures.append(f"用例2 顶部选区应靠近图像上沿, got y={iy_top}")

    # 用例3：靠近屏幕底部的选区 → 图像 y 应该很大（靠近底部）
    rect_bottom = (600.0, 10.0, 200.0, 40.0)  # AppKit y=10..50 靠下
    _, iy_bottom, _, _ = appkit_rect_to_image(rect_bottom)
    if iy_bottom < IMG_H - 200:
        failures.append(f"用例3 底部选区应靠近图像下沿, got y={iy_bottom}")

    # 用例4：上下颠倒检测
    # AppKit 里 upper(y=800) 在屏幕上方 → 图像行号应该**更小**
    # 不翻转 Y 的旧 bug 会让 upper 的行号反而更大，从而被本用例抓到
    upper = (0.0, 800.0, 300.0, 50.0)
    lower = (0.0, 100.0, 300.0, 50.0)
    _, uy, _, _ = appkit_rect_to_image(upper)
    _, ly, _, _ = appkit_rect_to_image(lower)
    if not (uy < ly):
        failures.append(f"用例4 上下关系颠倒: upper={uy}, lower={ly}")

    # 用例5：翻转逻辑等价于 point→row 换算
    # rect = (0, py, 10, 10)，选区跨越 py..py+10
    # 图像矩形的**下边** (iy + h) 应等于 AppKit 点 (py) 对应的行号
    py = 478.0
    _, iy, _, ih = appkit_rect_to_image((0.0, py, 10.0, 10.0))
    row = image_row_of_point(py)
    if abs((iy + ih) - row) > 0.01:
        failures.append(f"用例5 两种换算不一致: {iy + ih} vs {row}")

    # 用例6：裁剪矩形必须落在图像范围内
    for r in [(0, 0, SCREEN_W, SCREEN_H), (0, 0, 10, 10),
              (SCREEN_W - 10, SCREEN_H - 10, 10, 10)]:
        x, y, w, h = appkit_rect_to_image(r)
        if x < -0.01 or y < -0.01 or x + w > IMG_W + 0.01 or y + h > IMG_H + 0.01:
            failures.append(f"用例6 裁剪越界: {r} -> ({x},{y},{w},{h}) 图片 {IMG_W}x{IMG_H}")

    print(f"图片尺寸: {int(IMG_W)}x{int(IMG_H)}  屏幕: {int(SCREEN_W)}x{int(SCREEN_H)} 点 (scale={SCALE})")
    if failures:
        print("\n❌ 失败:")
        for f in failures:
            print("   -", f)
        return 1
    print("\n✅ 全部坐标换算用例通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
