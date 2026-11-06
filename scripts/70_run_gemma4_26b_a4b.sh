#!/usr/bin/env bash
# =============================================================================
# 70_run_gemma4_26b_a4b.sh — Gemma 4 26B-A4B (Apache-2.0) : "큰 두뇌" 하이브리드 서빙
#   전문가(ffn_*_exps)는 CPU RAM, 어텐션·공유 MLP·라우터·임베딩·KV 는 GPU.
#   실측 참고: 전문가 전부 CPU 로 두면 RTX 5070 Ti 16GB + 7945HX(WSL2)에서 30.1 tok/s(ik_llama #1765).
#   9700X + DDR5-6000 계획치 23~32 tok/s, 하한 ≈ 20 (미측정 — scripts/60_bench.sh 로 먼저 보정; docs/08 H3).
#
#   모델 파일(택1):
#     - google/gemma-4-26B-A4B-it-qat-q4_0-gguf : gemma-4-26B_q4_0-it.gguf (공식 QAT, 14.4 GB) ← Day-1
#     - unsloth/gemma-4-26B-A4B-it-qat-GGUF : UD-Q4_K_XL (QAT 인지 변환, ~14.3 GB). 드래프터 mtp-*.gguf 동봉
#     - 판매용 자체 빌드: scripts/40_quantize.sh <qat-unq.gguf> <out> Q4_0 recipes/gemma4_26b_a4b_qat_product.tensor-types.txt [imatrix]
#       (범용 recipes/moe_hybrid_8gb 는 Gemma 4 26B 의 704 열 텐서에서 폴백 → 사용 금지)
#   환경변수: MODEL, DRAFT(MTP gguf; 비우면 미사용), CTX=65536, NCMOE=24, CACHE_MIB=0, KV=q8_0, PORT=8080, THREADS=8
#             FIT=1 → -ngl/--n-cpu-moe 를 빼고 --fit on 으로 자동 배치(VRAM 을 모르는 고객 PC 용; --fit 은 명시하지 않은 인자만 조정)
#   Windows 데스크톱(실사용 VRAM ≈ 7.0 GiB)이면 NCMOE=26 부터. 첫 실행 로그 llama_memory_breakdown_print 와 nvidia-smi 여유 ≥ 0.5 GiB 확인.
#   주의(2026-11 기준 이슈): --mmproj(비전) 와 MTP 드래프터를 동시에 켜면 시작 시 abort(#30698) → 둘 중 하나만.
#        MTP 는 MoE 에서 이득이 작거나 없다는 보고(PR #23398 작성자) → 켜고 꺼서 60_bench 로 비교.
# =============================================================================
set -euo pipefail
MODEL="${MODEL:-models/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf}"
DRAFT="${DRAFT:-}"
CTX="${CTX:-65536}"; NCMOE="${NCMOE:-24}"; CACHE_MIB="${CACHE_MIB:-0}"; KV="${KV:-q8_0}"; PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"   # Linux 헤드리스 NCMOE=23
FIT="${FIT:-0}"; FIT_TARGET="${FIT_TARGET:-1280}"
# --moe-cache-mib 는 기본 끔: 작은 캐시 회귀(#31421), 이득 미측정 → 1024~1536 으로 A/B 할 때만 CACHE_MIB 지정

ARGS=(-m "$MODEL" --no-mmproj --jinja -fa on -t "$THREADS" -tb "$THREADS"
      -c "$CTX" -ctk "$KV" -ctv "$KV" -b 2048 -ub 512 -np 1
      --cache-ram 2048 --spec-default
      --temp 1.0 --top-p 0.95 --top-k 64
      --host 127.0.0.1 --port "$PORT")
if [ "$FIT" = "1" ]; then
  ARGS+=(--fit on --fit-target "$FIT_TARGET")
else
  ARGS+=(-ngl all --n-cpu-moe "$NCMOE" --fit off)
fi
[ "$CACHE_MIB" != "0" ] && ARGS+=(--moe-cache-mib "$CACHE_MIB")
if [ -n "$DRAFT" ]; then
  ARGS+=(-md "$DRAFT" --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.6 -ctkd "$KV" -ctvd "$KV")
fi
echo "[*] llama-server ${ARGS[*]}"
exec llama-server "${ARGS[@]}"
# 시작 로그 확인: 'KV buffer size', 'n_rot_k/n_rot_v'(Hadamard 회전), 'llama_memory_breakdown_print', 'moe_cache' 적중률
