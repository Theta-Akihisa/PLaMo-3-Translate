#!/bin/sh
# アプリアイコンを作り直す（Chromium + Playwright と Pillow が必要）
set -eu
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
node tools/app-icon/render.cjs "$tmp"
python3 tools/app-icon/export.py "$tmp"
rm -rf "$tmp"
