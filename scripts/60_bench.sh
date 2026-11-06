#!/usr/bin/env bash
# =============================================================================
# 60_bench.sh — llama-bench 로 설정 매트릭스 성능 측정 (pp=프롬프트 처리, tg=토큰 생성)
#
#   사용법:
#     scripts/60_bench.sh <model.gguf> [n_cpu_moe 리스트] [kv 타입 리스트]
#   예:
#     scripts/60_bench.sh gpt-oss-20b-mxfp4.gguf "24,16,12,8" "f16,q8_0"
#     scripts/60_bench.sh gemma4-e4b-Q4_K_M.gguf "0" "f16,q8_0,q4_0"
#   환경변수: THREADS=8 PP=1024 TG=128 DEPTH=8192 REPS=3 OUT=md (csv|json|jsonl|md|sql) EXTRA="-ot ..."
#   -d DEPTH : 이미 DEPTH 토큰이 채워진 컨텍스트에서의 속도(실사용에 가까움)
# =============================================================================
set -euo pipefail
MODEL="${1:?model.gguf}"
NCMOE_LIST="${2:-0}"
KV_LIST="${3:-f16}"
THREADS="${THREADS:-8}"; PP="${PP:-1024}"; TG="${TG:-128}"; DEPTH="${DEPTH:-0}"; REPS="${REPS:-3}"; OUT="${OUT:-md}"; EXTRA="${EXTRA:-}"

echo "[*] 장치:"; llama-bench --list-devices 2>/dev/null || true
IFS=',' read -ra NCMOES <<< "$NCMOE_LIST"
IFS=',' read -ra KVS <<< "$KV_LIST"
for kv in "${KVS[@]}"; do
  for nc in "${NCMOES[@]}"; do
    echo; echo "### n_cpu_moe=$nc  kv=$kv  depth=$DEPTH"
    # shellcheck disable=SC2086
    llama-bench -m "$MODEL" -ngl 99 -ncmoe "$nc" -fa on -ctk "$kv" -ctv "$kv" \
      -t "$THREADS" -p "$PP" -n "$TG" -d "$DEPTH" -r "$REPS" -o "$OUT" --progress $EXTRA
  done
done
