#!/usr/bin/env bash
# =============================================================================
# 45_convert_nvfp4_checkpoint.sh — NVIDIA ModelOpt / compressed-tensors NVFP4 체크포인트 → GGUF(NVFP4)
#
#   llama.cpp 는 "이미 NVFP4 로 양자화된" HF 체크포인트를 GGUF 로 변환해 Blackwell FP4 텐서코어(W4A4)로 돌립니다.
#     - ModelOpt NVFP4 (예: nvidia/*-NVFP4, nvidia/gemma-4-31b-it-nvfp4)                → 지원
#     - llm-compressor / compressed-tensors NVFP4 (예: RedHatAI/*-NVFP4)  (PR #21095, 2026-05) → 지원
#   8GB 카드에서 NVFP4 체크포인트 자체를 만드는 것(ModelOpt PTQ)은 bf16 모델 전체를 GPU 에 올려야 해 보통 불가능.
#   → 허브의 공식 NVFP4 체크포인트를 받아 변환만 로컬에서 수행하거나, 클라우드 GPU 에서 PTQ 후 가져옵니다.
#
#   사용법:
#     scripts/45_convert_nvfp4_checkpoint.sh <hf-nvfp4-dir> <out.gguf> [--no-mtp]
#   실행 시 프리필 가속(네이티브 W4A4) 강제:  GGML_CUDA_MMQ_PREC=q4 llama-server ...
#   기본(auto)은 W4A16 로 표시된 층을 W4A8 경로로 돌려 정확도를 우선합니다.
# =============================================================================
set -euo pipefail
SRC="${1:?NVFP4 HF checkpoint dir}"; OUT="${2:?out.gguf}"; shift 2
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
python3 "$LLAMA_DIR/convert_hf_to_gguf.py" "$SRC" --outfile "$OUT" "$@"
echo "[OK] $OUT"
python3 - "$OUT" <<'PY'
import sys
from gguf import GGUFReader
r = GGUFReader(sys.argv[1])
from collections import Counter
c = Counter(t.tensor_type.name for t in r.tensors)
print("텐서 타입 분포:", dict(c))
PY
