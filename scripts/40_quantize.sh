#!/usr/bin/env bash
# =============================================================================
# 40_quantize.sh — 레시피 기반 혼합정밀도(mixed-precision) GGUF 양자화
#
#   llama-quantize 의 고급 옵션을 한 줄로 묶습니다:
#     --imatrix               : 30_imatrix.sh 결과
#     --tensor-type-file      : recipes/<name>.tensor-types.txt (정규식=타입, 한 줄에 하나)
#     --token-embedding-type  : 입력 임베딩 타입 (호스트 메모리에 있으므로 넉넉히 q8_0 가능)
#     --output-tensor-type    : lm_head 타입 (품질에 민감 → q6_k/q8_0 권장)
#   지원 타입(2026-11 llama.cpp master): q1_0 q2_0 iq1_s iq1_m iq2_xxs iq2_xs iq2_s iq2_m q2_k iq3_xxs iq3_xs iq3_s iq3_m
#     q3_k q4_0 q4_1 iq4_nl iq4_xs q4_k q5_0 q5_1 q5_k q6_k q8_0 mxfp4 nvfp4 tq1_0 tq2_0 f16 bf16
#   ※ nvfp4(4.5bpw, Blackwell FP4 텐서코어 네이티브)와 mxfp4(4.25bpw)는 --tensor-type 정규식으로 지정합니다.
#
#   사용법:
#     scripts/40_quantize.sh <in-f16.gguf> <out.gguf> <BASE_FTYPE> <recipe.txt> [imatrix.gguf]
#   예:
#     scripts/40_quantize.sh gemma4-26b-f16.gguf gemma4-26b-UD.gguf IQ4_XS recipes/moe_hybrid_8gb.tensor-types.txt gemma4.imatrix.gguf
#   환경변수: EMBED_TYPE=q8_0 OUTPUT_TYPE=q8_0 THREADS=8 EXTRA="--leave-output-tensor"
# =============================================================================
set -euo pipefail
IN="${1:?in.gguf}"; OUT="${2:?out.gguf}"; FTYPE="${3:?BASE_FTYPE (예: IQ4_XS, Q4_K_M, Q5_K_M, MXFP4_MOE, Q8_0)}"; RECIPE="${4:?recipe tensor-types file}"
IMATRIX="${5:-}"
EMBED_TYPE="${EMBED_TYPE:-q8_0}"; OUTPUT_TYPE="${OUTPUT_TYPE:-q8_0}"; THREADS="${THREADS:-8}"; EXTRA="${EXTRA:-}"

ARGS=()
[ -n "$IMATRIX" ] && ARGS+=(--imatrix "$IMATRIX")
ARGS+=(--tensor-type-file "$RECIPE")
ARGS+=(--token-embedding-type "$EMBED_TYPE" --output-tensor-type "$OUTPUT_TYPE")
# shellcheck disable=SC2206
[ -n "$EXTRA" ] && ARGS+=($EXTRA)

echo "[*] 레시피: $RECIPE"
grep -vE '^\s*(#|$)' "$RECIPE" | sed 's/^/    /'
echo "[*] llama-quantize ${ARGS[*]} $IN $OUT $FTYPE $THREADS"
llama-quantize "${ARGS[@]}" "$IN" "$OUT" "$FTYPE" "$THREADS"

echo "[OK] $(du -h "$OUT" | cut -f1)  $OUT"
echo "    다음: scripts/50_eval_kld.sh 로 원본 대비 KL-divergence 측정"
