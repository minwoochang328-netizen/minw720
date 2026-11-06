#!/usr/bin/env bash
# =============================================================================
# 71_run_gpt_oss_20b.sh — gpt-oss-20b (Apache-2.0, 네이티브 MXFP4) : 추론·도구호출 특화 하이브리드
#   실측: RTX 5060 8GB + 32GB DDR5, --n-cpu-moe 18, 64K ctx → 33~35 tok/s (hindsight #2525). 공식 8GB 레시피: --n-cpu-moe 22(128K) / 16(32K).
#   한국어는 보통 수준(MMMLU-ko 75.7) → 한국어 주력이면 Gemma 4 / Kanana-2 를 우선.
#   모델: ggml-org/gpt-oss-20b-GGUF (gpt-oss-20b-mxfp4.gguf, 12.1 GB) — MXFP4 전문가를 그대로 쓸 것(재양자화 금지)
#   환경변수: MODEL, CTX=65536, NCMOE=16, CACHE_MIB=1536, EFFORT=medium(low|medium|high), PORT=8080, THREADS=8
#   KV: gpt-oss 는 K 를 q4_0 으로 내리면 AIME25 가 37.9→21.7% 로 급락(회전 적용 후에도) → K 는 q8_0 이상 유지.
# =============================================================================
set -euo pipefail
MODEL="${MODEL:-models/gpt-oss-20b-mxfp4.gguf}"
CTX="${CTX:-65536}"; NCMOE="${NCMOE:-16}"; CACHE_MIB="${CACHE_MIB:-1536}"; EFFORT="${EFFORT:-medium}"; PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"
FIT_TARGET="${FIT_TARGET:-768}"
exec llama-server -m "$MODEL" --jinja -fa on -t "$THREADS" -tb "$THREADS" \
  -c "$CTX" -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 -np 1 \
  -ngl all --n-cpu-moe "$NCMOE" --moe-cache-mib "$CACHE_MIB" \
  --fit on --fit-target "$FIT_TARGET" --cache-ram 2048 \
  --spec-default --reasoning-format auto \
  --chat-template-kwargs "{\"reasoning_effort\":\"$EFFORT\"}" \
  --temp 1.0 --top-p 1.0 --top-k 0 \
  --host 127.0.0.1 --port "$PORT"
