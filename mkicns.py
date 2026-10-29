#!/usr/bin/env python3
"""生成 macOS .icns 文件（绕过 iconutil，直接写 ICNS 容器格式）。

ICNS 格式：'icns' magic + 总长度，然后是一系列 chunk：
    [4字节 type][4字节 length][payload]
每种尺寸对应一种 type，其中 PNG 格式的 payload 直接是 PNG 字节。
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# (输出type, 实际像素尺寸, 是否@2x)
SPECS = [
    (b"icp4", 16, False),
    (b"icp5", 32, False),
    (b"icp6", 32, True),
    (b"ic07", 128, False),
    (b"ic08", 256, False),
    (b"ic09", 512, False),
    (b"ic10", 1024, False),
    (b"ic11", 32, True),
    (b"ic12", 64, True),
    (b"ic13", 256, True),
    (b"ic14", 512, True),
]


def resize(src: Path, size: int) -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        subprocess.run(
            ["sips", "-z", str(size), str(size), str(src), "--out", str(tmp_path)],
            check=True, capture_output=True,
        )
        return tmp_path.read_bytes()
    finally:
        tmp_path.unlink(missing_ok=True)


def build_icns(src: Path, out: Path) -> None:
    chunks = []
    for icns_type, size, _ in SPECS:
        payload = resize(src, size)
        # ICNS chunk 长度包含 8 字节头
        chunks.append(icns_type + struct.pack(">I", len(payload) + 8) + payload)

    body = b"".join(chunks)
    out.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"icns written: {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: mkicns.py <source.png> <out.icns>")
        sys.exit(1)
    build_icns(Path(sys.argv[1]), Path(sys.argv[2]))
