#!/usr/bin/env bash
# =============================================================================
# 74_run_kanana2_30b_a3b.sh — Kakao Kanana-2 30B-A3B-instruct-2601 : 한국어 최강 오픈 MoE (KMMLU 68.26)
#   라이선스 주의: Kanana License — 자사 서비스 운영은 가능, 모델 재배포/API 상품화/디바이스 탑재/MAU 1천만↑ 는 카카오 별도 계약(alpha.k@kakaocorp.com).
#   llama.cpp 지원: PR #19803 (2026-02-22). MLA 어텐션 → KV 작음. 32K 네이티브(YaRN 128K).
#   GGUF: 공개 GGUF 확인 안 됨 → convert_hf_to_gguf.py 로 변환 후 scripts/40_quantize.sh (recipes/moe_hybrid_8gb) 권장.
#   샘플링(카카오 권장): temp 0.6, top_p 0.95, top_k 20 — greedy 금지(반복 루프).
#   환경변수: MODEL, CTX=32768, NCMOE=48, CACHE_MIB=1536, PORT=8080, THREADS=8
# =============================================================================
set -euo pipefail
MODEL="${MODEL:-models/kanana-2-30b-a3b-instruct-2601-HYB.gguf}"
CTX="${CTX:-32768}"; NCMOE="${NCMOE:-48}"; CACHE_MIB="${CACHE_MIB:-1536}"; PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"
exec llama-server -m "$MODEL" --jinja -fa on -t "$THREADS" -tb "$THREADS" \
  -c "$CTX" -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 -np 1 \
  -ngl all --n-cpu-moe "$NCMOE" --moe-cache-mib "$CACHE_MIB" \
  --fit on --fit-target 768 --cache-ram 2048 --spec-default \
  --temp 0.6 --top-p 0.95 --top-k 20 \
  --host 127.0.0.1 --port "$PORT"
