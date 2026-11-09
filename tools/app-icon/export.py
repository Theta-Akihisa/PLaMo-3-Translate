#!/usr/bin/env python3
"""原本 PNG（render.cjs の出力）から iOS / macOS / Chrome 拡張機能のアイコンを書き出す。

usage: python3 tools/app-icon/export.py <原本ディレクトリ>
"""
import json
import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
masters = pathlib.Path(sys.argv[1])
full = Image.open(masters / "full.png").convert("RGBA")
rounded = Image.open(masters / "rounded.png").convert("RGBA")
simple = Image.open(masters / "rounded-simple.png").convert("RGBA")


def resized(img, px):
    return img.resize((px, px), Image.LANCZOS)


# iOS: 1024 の 1 枚（App Store の要件で透過なし）
ios = ROOT / "apple/App/iOS/Assets.xcassets/AppIcon.appiconset"
ios.mkdir(parents=True, exist_ok=True)
bg = Image.new("RGB", full.size, (37, 99, 235))
bg.paste(full, mask=full.split()[3])
bg.save(ios / "AppIcon-1024.png")
(ios / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1},
}, indent=2) + "\n")

# macOS: 16〜512 の 1x / 2x
mac = ROOT / "apple/App/macOS/Assets.xcassets/AppIcon.appiconset"
mac.mkdir(parents=True, exist_ok=True)
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        resized(simple if px <= 32 else rounded, px).save(mac / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
(mac / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

for d in (ios.parent, mac.parent):
    (d / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

# Chrome 拡張機能
ext = ROOT / "chrome-extension/public/icons"
for px in (16, 32, 48, 128):
    resized(simple if px <= 32 else rounded, px).save(ext / f"icon{px}.png")

# README などで使うプレビュー
resized(rounded, 512).save(ROOT / "tools/app-icon/preview.png")
print("exported icons")
