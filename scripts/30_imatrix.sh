#!/usr/bin/env bash
# =============================================================================
# 30_imatrix.sh — 중요도 행렬(importance matrix) 생성
#
#   imatrix 는 "어떤 가중치가 실제 활성화에 중요한가"를 캘리브레이션 텍스트로 측정해
#   저비트(IQ2/IQ3/IQ4, Q4_K 등) 양자화의 품질을 크게 올립니다. 한국어+영어+코드가 섞인
#   calib/calibration_ko_en_code.txt 를 쓰면 한국어 성능 보존에 유리합니다.
#
#   사용법:
#     scripts/30_imatrix.sh <model-f16-or-bf16.gguf> [calib.txt] [out.imatrix.gguf]
#   환경변수:
#     NGL=99          GPU 에 올릴 레이어 수
#     CTX=2048        청크(컨텍스트) 길이. 512(기본 관행) ~ 8192(긴 문맥 품질↑, 느림)
#     CHUNKS=256      처리할 청크 수 (-1 = 전부)
#     MOE_CPU=auto    MoE 모델이면 전문가를 CPU 에 두고(--cpu-moe) 어텐션만 GPU. 8GB VRAM 필수 설정.
#     THREADS=8       9700X 물리 코어 수
#   비고: F16/BF16 원본이 8GB 에 안 들어가도 됩니다 — 가중치는 RAM 에서 mmap 되고,
#         GPU 에는 비전문가 레이어만 올라갑니다. (gpt-oss-20b F16 13.8GB + 32GB RAM = OK)
# =============================================================================
set -euo pipefail
MODEL="${1:?사용법: $0 <model.gguf> [calib.txt] [out.gguf]}"
CALIB="${2:-$(dirname "$0")/../calib/calibration_ko_en_code.txt}"
OUT="${3:-${MODEL%.gguf}.imatrix.gguf}"
NGL="${NGL:-99}"; CTX="${CTX:-2048}"; CHUNKS="${CHUNKS:-256}"; THREADS="${THREADS:-8}"; MOE_CPU="${MOE_CPU:-auto}"

[ -f "$CALIB" ] || { echo "[!] 캘리브레이션 파일이 없습니다: $CALIB  → python calib/build_calibration_set.py 먼저 실행" >&2; exit 1; }

MOE_FLAGS=()
if [ "$MOE_CPU" = "auto" ]; then
  # GGUF 메타데이터에 expert_count 가 있으면 MoE 로 판단
  if python3 - "$MODEL" <<'PY' 2>/dev/null
import sys
from gguf import GGUFReader
r = GGUFReader(sys.argv[1])
sys.exit(0 if any(k.endswith('.expert_count') for k in r.fields) else 1)
PY
  then MOE_FLAGS=(--cpu-moe); echo "[*] MoE 감지 → 전문가 가중치는 CPU(RAM), 어텐션/라우터/임베딩만 GPU"; fi
elif [ "$MOE_CPU" = "1" ]; then MOE_FLAGS=(--cpu-moe); fi

echo "[*] imatrix 생성: $MODEL"
echo "    calib=$CALIB ctx=$CTX chunks=$CHUNKS → $OUT"
llama-imatrix \
  -m "$MODEL" -f "$CALIB" -o "$OUT" \
  -ngl "$NGL" -c "$CTX" -b "$CTX" -ub 512 \
  --chunks "$CHUNKS" --output-frequency 20 \
  -t "$THREADS" -fa on \
  "${MOE_FLAGS[@]}"

echo "[OK] $OUT"
llama-imatrix --in-file "$OUT" --show-statistics 2>/dev/null | head -40 || true
