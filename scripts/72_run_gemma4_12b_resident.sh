#!/usr/bin/env bash
# =============================================================================
# 72_run_gemma4_12b_resident.sh — Gemma 4 12B Unified (Apache-2.0) : 8GB 에 "통째로" + MTP 드래프터
#   핵심 조건: 48층 전부 GPU 상주(파일 ≤ ~6.3 GB). 실측: RTX 5060 Laptop 8GB, 6.18 GB imatrix 양자화 + MTP Q6_K,
#   n_max 2, 16K q8_0 KV → 27.4 → 40.4 tok/s (llama.cpp 토론 #25357). 4~6층만 CPU 로 넘어가도 MTP 이득이 사라짐(10~14 tok/s).
#   파일 만들기: scripts/40_quantize.sh <bf16> <out> IQ3_M recipes/dense_3bit_14b_8gb.tensor-types.txt <imatrix>
#               (또는 EXL3 3.0~3.5 bpw → exllamav3/TabbyAPI 로 서빙)
#   환경변수: MODEL, DRAFT(mtp-gemma-4-12B-it-Q6_K.gguf 등), CTX=16384, KV=q8_0, PORT=8080
#   주의: 드래프터 acceptance 는 복사 거리 1,024 토큰 넘으면 0.90→0.75 로 하락(#31089). --mmproj 와 MTP 동시 사용 금지(#30698).
# =============================================================================
set -euo pipefail
MODEL="${MODEL:-models/gemma-4-12B-it-IQ3_M-ud.gguf}"
DRAFT="${DRAFT:-models/mtp-gemma-4-12B-it-Q6_K.gguf}"
CTX="${CTX:-16384}"; KV="${KV:-q8_0}"; PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"
ARGS=(-m "$MODEL" --no-mmproj --jinja -fa on -t "$THREADS"
      -c "$CTX" -ctk "$KV" -ctv "$KV" -b 2048 -ub 512 -np 1 --parallel 1
      -ngl all --fit off --cache-ram 2048
      --host 127.0.0.1 --port "$PORT")
if [ -n "$DRAFT" ] && [ -f "$DRAFT" ]; then
  ARGS+=(-md "$DRAFT" --spec-type draft-mtp --spec-draft-n-max 2 -ngld all -ctkd "$KV" -ctvd "$KV")
else
  ARGS+=(--spec-default)
fi
echo "[*] llama-server ${ARGS[*]}"
exec llama-server "${ARGS[@]}"
# 로그에서 'offloaded 48/48 layers' 가 아니면 더 작은 양자화(또는 KV q4_0)로 내려야 MTP 가 이득을 냄
