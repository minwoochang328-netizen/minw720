#!/usr/bin/env bash
# =============================================================================
# 73_run_gemma4_e4b.sh — Gemma 4 E4B (Apache-2.0) : 완전 상주 고속 비서 (텍스트+이미지+오디오)
#   기대치 65~75 tok/s(텍스트), 비전 프로젍터 사용 시 VRAM +~1.2 GB. 공식 QAT Q4_0 GGUF(unsloth/gemma-4-E4B-it-qat-GGUF).
#   PLE(레이어별 임베딩)는 --lazy-mode on 으로 디스크/호스트에 두어 VRAM 절약.
#   환경변수: MODEL, MMPROJ(비전 사용 시 경로), CTX=32768, KV=q8_0, PORT=8080
#   주의: E4B 의 MTP 드래프터는 acceptance 0.4~0.5 로 낮고 --kv-unified 와 충돌(#31482) → 미사용 권장.
# =============================================================================
set -euo pipefail
MODEL="${MODEL:-models/gemma-4-E4B-it-qat-Q4_0.gguf}"
MMPROJ="${MMPROJ:-}"
CTX="${CTX:-32768}"; KV="${KV:-q8_0}"; PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"
ARGS=(-m "$MODEL" --jinja -fa on -t "$THREADS" -c "$CTX" -ctk "$KV" -ctv "$KV" -b 2048 -ub 512 -np 1
      -ngl all --lazy-mode on --fit on --fit-target 768 --spec-default --host 127.0.0.1 --port "$PORT")
if [ -n "$MMPROJ" ]; then ARGS+=(--mmproj "$MMPROJ"); else ARGS+=(--no-mmproj); fi
echo "[*] llama-server ${ARGS[*]}"
exec llama-server "${ARGS[@]}"
