# PLaMo 3 Translate (GGUF) を Hugging Face から取得し、llama-server (llama.cpp) で起動する (Windows)
# 使い方: .\run-llama-server.ps1 [-Size 0.8b|2b|8b] [-Quant Q4_K_M] [-Port 8080] [-LlamaServer llama-server.exe]
param(
  [ValidateSet('0.8b', '2b', '8b')] [string]$Size = '0.8b',
  [string]$Quant = 'Q4_K_M',
  [int]$Port = 8080,
  [string]$ModelDir = (Join-Path $env:USERPROFILE '.cache\plamo-3-translate'),
  [string]$LlamaServer = 'llama-server'
)
$ErrorActionPreference = 'Stop'

$file = "plamo-3-translate-$Size-$Quant.gguf"
$url = "https://huggingface.co/pfnet/plamo-3-translate-$Size-GGUF/resolve/main/$file"
$dest = Join-Path $ModelDir $file

if (-not (Get-Command $LlamaServer -ErrorAction SilentlyContinue)) {
  Write-Error "llama-server が見つかりません。https://github.com/ggml-org/llama.cpp/releases から取得し (PLaMo 3 対応版 = 2026-11 以降)、PATH を通すか -LlamaServer でパスを指定してください。"
}

New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) {
  Write-Host "ダウンロード: $url"
  $part = "$dest.part"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $url -OutFile $part
  Move-Item -Force $part $dest
}

Write-Host "起動: $LlamaServer -m $dest --port $Port"
& $LlamaServer -m $dest --host 127.0.0.1 --port $Port -c 8192 --jinja --no-prefill-assistant
