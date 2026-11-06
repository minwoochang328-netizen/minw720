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
#     scripts/40_quantize.sh gemma4-26b-qat-unq.gguf gemma4-26b-S.gguf Q4_0 recipes/gemma4_26b_a4b_qat_product.tensor-types.txt gemma4.imatrix.gguf
#     scripts/40_quantize.sh nemotron-bf16.gguf nemotron-HYB.gguf IQ4_XS recipes/moe_hybrid_8gb.tensor-types.txt nemotron.imatrix.gguf
#   환경변수: EMBED_TYPE=q8_0 OUTPUT_TYPE=q8_0 THREADS=8 EXTRA="--leave-output-tensor"
#             ALLOW_FALLBACK=1  → 블록 폴백 경고가 있어도 실패로 처리하지 않음(기본은 실패)
#   ⚠ 행 길이(ne0)가 256 의 배수가 아닌 텐서(예: Gemma 4 26B-A4B ffn_down_exps 704, 공유 ffn_down 2112)에
#     K/I-quant 를 지정하면 llama-quantize 가 경고를 찍고 Q6_K→Q8_0, Q5_K→Q5_1, Q4_K→Q5_0, IQ*→IQ4_NL 로 바꿉니다
#     (llama-quant.cpp tensor_type_fallback). 이 스크립트는 로그에서 그 경고를 찾아 빌드를 실패시킵니다.
#     그런 텐서에는 블록-32(q4_0/q4_1/q5_0/q5_1/q8_0/iq4_nl/mxfp4) 또는 블록-64(nvfp4/q2_0) 타입을 명시하세요.
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
LOG="${OUT%.gguf}.quantize.log"
llama-quantize "${ARGS[@]}" "$IN" "$OUT" "$FTYPE" "$THREADS" 2>&1 | tee "$LOG"

# 블록 폴백 게이트(G0): "not divisible" / "required fallback quantization" 경고 검사
if grep -qE 'not divisible|required fallback quantization' "$LOG"; then
  echo "[!] 블록 폴백 발생 — 레시피가 의도한 타입과 실제 타입이 다릅니다:"
  grep -E 'not divisible|required fallback quantization' "$LOG" | head -20 | sed 's/^/    /'
  if [ "${ALLOW_FALLBACK:-0}" != "1" ]; then
    echo "[X] 레시피에 해당 텐서의 블록-32/64 타입을 명시한 뒤 다시 실행하세요(무시하려면 ALLOW_FALLBACK=1)."
    exit 2
  fi
fi

echo "[OK] $(du -h "$OUT" | cut -f1)  $OUT"
echo "    다음: scripts/50_eval_kld.sh 로 원본 대비 KL-divergence 측정"
