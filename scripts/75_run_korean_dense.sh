#!/usr/bin/env bash
# =============================================================================
# 75_run_korean_dense.sh — 깨끗한 라이선스의 한국어 밀집 모델 (완전 상주)
#   mi:dm     : KT Mi:dm 2.0 Base-Instruct 11.5B (MIT)  — IQ4_XS(≈6.2GB)/IQ3_M(≈5.3GB) 로 통째 상주, ctx 8~16K
#   ax31      : SKT A.X 3.1 Light 7B (Apache-2.0)        — MHA(32 KV heads) → KV 512 KiB/token(f16)! q8_0 KV + ctx ≤ 8~16K 필수
#   kanana15  : Kakao Kanana-1.5 8B (Apache-2.0)         — GQA, 32K(YaRN 128K)
#   사용법: scripts/75_run_korean_dense.sh <midm|ax31|kanana15> [model.gguf]
# =============================================================================
set -euo pipefail
KIND="${1:?midm|ax31|kanana15}"; MODEL="${2:-}"
PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"
case "$KIND" in
  midm)     MODEL="${MODEL:-models/Midm-2.0-Base-Instruct-IQ4_XS.gguf}"; CTX="${CTX:-12288}"; KV="${KV:-q8_0}";;
  ax31)     MODEL="${MODEL:-models/A.X-3.1-Light-Q4_K_M.gguf}";          CTX="${CTX:-8192}";  KV="${KV:-q8_0}";;
  kanana15) MODEL="${MODEL:-models/kanana-1.5-8b-instruct-Q4_K_M.gguf}";  CTX="${CTX:-32768}"; KV="${KV:-q8_0}";;
  *) echo "unknown: $KIND" >&2; exit 2;;
esac
exec llama-server -m "$MODEL" --jinja -fa on -t "$THREADS" -c "$CTX" -ctk "$KV" -ctv "$KV" -b 2048 -ub 512 -np 1 \
  -ngl all --fit on --fit-target 768 --spec-default --host 127.0.0.1 --port "$PORT"
