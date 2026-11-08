#!/bin/bash
# shared/*.json を Swift パッケージのリソース／テストリソースへコピーして同期する。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/apple/PlamoTranslateKit"
mkdir -p "$PKG/Sources/PlamoTranslateCore/Resources" "$PKG/Tests/PlamoTranslateCoreTests/Resources"
cp "$ROOT/shared/languages.json" "$ROOT/shared/models.json" "$PKG/Sources/PlamoTranslateCore/Resources/"
cp "$ROOT/shared/pfml3-test-vectors.json" "$PKG/Tests/PlamoTranslateCoreTests/Resources/"
echo "synced shared/*.json -> $PKG"
