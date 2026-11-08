#!/bin/sh
# XcodeGen をインストールして Xcode プロジェクトを生成する
set -eu
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
mkdir -p Config
xcodegen generate
echo "OK: PlamoTranslate.xcodeproj を生成しました"
