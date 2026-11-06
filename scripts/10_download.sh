#!/usr/bin/env bash
# =============================================================================
# 10_download.sh — Hugging Face 에서 모델(GGUF 또는 원본 safetensors) 내려받기
#
#   pip install -U "huggingface_hub[cli]"   →  `hf` CLI (구버전은 huggingface-cli)
#   사용법:
#     scripts/10_download.sh <repo_id> [include-glob] [dest-dir]
#   예:
#     scripts/10_download.sh ggml-org/gpt-oss-20b-GGUF "*mxfp4*.gguf" models/
#     scripts/10_download.sh google/gemma-4-E4B-it "*" models/gemma-4-E4B-it      # 원본(safetensors) → 직접 변환/양자화용
#   게이트 모델(Gemma/Llama)은 `hf auth login` 으로 먼저 로그인.
# =============================================================================
set -euo pipefail
REPO="${1:?repo_id}"; INCLUDE="${2:-*}"; DEST="${3:-models/$(basename "$REPO")}"
mkdir -p "$DEST"
if command -v hf >/dev/null 2>&1; then
  hf download "$REPO" --include "$INCLUDE" --local-dir "$DEST"
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$REPO" --include "$INCLUDE" --local-dir "$DEST"
else
  echo "[!] hf CLI 가 없습니다: pip install -U 'huggingface_hub[cli]'" >&2; exit 1
fi
echo "[OK] $DEST"; ls -la "$DEST" | head -30
