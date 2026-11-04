#!/usr/bin/env bash
# =============================================================================
# 50_eval_kld.sh — 양자화 품질 측정: KL-divergence(원본 로짓 대비) + 퍼플렉서티
#
#   PPL 만 보면 속습니다. llama.cpp 의 --kl-divergence 는 원본(F16/BF16) 로짓 분포와
#   양자화 모델의 분포 차이(평균/99%/최대 KLD, 정답토큰 확률 변화 Δp)를 직접 측정합니다.
#   가이드(경험적): 평균 KLD < 0.01 = 사실상 무손실, 0.01~0.05 = 좋음, 0.05~0.1 = 체감 가능, > 0.2 = 열화 큼
#
#   1) 기준 로짓 저장 (한 번만; 모델당 수 GB~수십 GB):
#        scripts/50_eval_kld.sh base  <model-f16.gguf> <eval.txt> <base.kld>
#   2) 양자화 모델 평가:
#        scripts/50_eval_kld.sh eval  <model-quant.gguf> <base.kld>
#   환경변수: CTX=2048 CHUNKS=64 NGL=99 THREADS=8 MOE_CPU=auto  (평가 텍스트는 캘리브레이션과 "다른" 텍스트를 쓸 것!)
#   8GB 팁: F16 기준 모델도 MoE 는 --cpu-moe 로, 밀집 14B 는 --n-cpu-ffn 로 실행 가능(느리지만 한 번뿐).
# =============================================================================
set -euo pipefail
MODE="${1:?base|eval}"
CTX="${CTX:-2048}"; CHUNKS="${CHUNKS:-64}"; NGL="${NGL:-99}"; THREADS="${THREADS:-8}"; MOE_CPU="${MOE_CPU:-auto}"

moe_flags() {
  local m="$1"
  if [ "$MOE_CPU" = "auto" ] && python3 - "$m" <<'PY' 2>/dev/null
import sys
from gguf import GGUFReader
sys.exit(0 if any(k.endswith('.expert_count') for k in GGUFReader(sys.argv[1]).fields) else 1)
PY
  then echo "--cpu-moe"; elif [ "$MOE_CPU" = "1" ]; then echo "--cpu-moe"; fi
}

case "$MODE" in
  base)
    MODEL="${2:?base model gguf}"; TEXT="${3:?eval text}"; KLD="${4:?out .kld}"
    echo "[*] 기준 로짓 저장: $MODEL → $KLD (chunks=$CHUNKS ctx=$CTX)"
    # shellcheck disable=SC2046
    llama-perplexity -m "$MODEL" -f "$TEXT" -c "$CTX" -b "$CTX" --chunks "$CHUNKS" -ngl "$NGL" -t "$THREADS" -fa on \
      --kl-divergence-base "$KLD" $(moe_flags "$MODEL")
    ;;
  eval)
    MODEL="${2:?quant model gguf}"; KLD="${3:?base .kld}"
    echo "[*] KLD 평가: $MODEL vs $KLD"
    # shellcheck disable=SC2046
    llama-perplexity -m "$MODEL" -c "$CTX" -b "$CTX" --chunks "$CHUNKS" -ngl "$NGL" -t "$THREADS" -fa on \
      --kl-divergence --kl-divergence-base "$KLD" $(moe_flags "$MODEL")
    ;;
  *) echo "사용법: $0 base <f16.gguf> <eval.txt> <out.kld> | eval <quant.gguf> <base.kld>" >&2; exit 2;;
esac
