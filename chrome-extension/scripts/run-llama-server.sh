#!/usr/bin/env bash
# PLaMo 3 Translate (GGUF) を Hugging Face から取得し、llama-server (llama.cpp) で起動する。
# 使い方: ./run-llama-server.sh [0.8b|2b|8b] [量子化 (既定 Q4_K_M)]
#   環境変数: PORT (既定 8080), MODEL_DIR (既定 ~/.cache/plamo-3-translate), LLAMA_SERVER (llama-server のパス)
# 拡張機能の設定: バックエンド「ローカルサーバー」 / エンドポイント http://127.0.0.1:8080
set -euo pipefail

SIZE="${1:-0.8b}"
QUANT="${2:-Q4_K_M}"
PORT="${PORT:-8080}"
MODEL_DIR="${MODEL_DIR:-$HOME/.cache/plamo-3-translate}"
LLAMA_SERVER="${LLAMA_SERVER:-llama-server}"

case "$SIZE" in
  0.8b|2b|8b) ;;
  *) echo "サイズは 0.8b / 2b / 8b のいずれかを指定してください: $SIZE" >&2; exit 1 ;;
esac

FILE="plamo-3-translate-${SIZE}-${QUANT}.gguf"
URL="https://huggingface.co/pfnet/plamo-3-translate-${SIZE}-GGUF/resolve/main/${FILE}"
DEST="${MODEL_DIR}/${FILE}"

if ! command -v "$LLAMA_SERVER" >/dev/null 2>&1; then
  cat >&2 <<MSG
llama-server が見つかりません。次のいずれかで入手してください:
  macOS:   brew install llama.cpp
  その他:  https://github.com/ggml-org/llama.cpp/releases から取得 (PLaMo 3 対応版 = 2026-11 以降のビルド)
パスを指定する場合: LLAMA_SERVER=/path/to/llama-server $0 $SIZE
MSG
  exit 1
fi

mkdir -p "$MODEL_DIR"
if [ ! -s "$DEST" ]; then
  echo "ダウンロード: $URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -C - -o "${DEST}.part" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -c -O "${DEST}.part" "$URL"
  else
    echo "curl か wget が必要です" >&2; exit 1
  fi
  mv "${DEST}.part" "$DEST"
fi

echo "起動: $LLAMA_SERVER -m $DEST --port $PORT"
exec "$LLAMA_SERVER" -m "$DEST" --host 127.0.0.1 --port "$PORT" -c 8192 --jinja --no-prefill-assistant
