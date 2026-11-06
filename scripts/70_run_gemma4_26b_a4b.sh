#!/usr/bin/env bash
# =============================================================================
# 70_run_gemma4_26b_a4b.sh — Gemma 4 26B-A4B (Apache-2.0) : "큰 두뇌" 하이브리드 서빙
#   전문가(ffn_*_exps)는 CPU RAM, 어텐션·공유 MLP·라우터·임베딩·KV 는 GPU.
#   실측 참고: 전문가 전부 CPU 로 두면 7945HX/DDR5 에서 30.1 tok/s(llama.cpp 토론, ik_llama #1765), 8GB 카드류 20~30 tok/s.
#   9700X + DDR5-6000 기대치 25~35 tok/s (GPU 에 전문가 8~12층 남길수록 ↑).
#
#   모델 파일(택1):
#     - unsloth/gemma-4-26B-A4B-it-qat-GGUF : UD-Q4_K_XL (QAT 가중치, ~14.3 GB) ← 권장. 드래프터 mtp-*.gguf 동봉
#     - ggml-org/gemma-4-26B-A4B-it-GGUF    : Q4_K_M (~16 GB)
#     - 직접 양자화: scripts/40_quantize.sh ... recipes/moe_hybrid_8gb.tensor-types.txt
#   환경변수: MODEL, DRAFT(MTP gguf; 비우면 미사용), CTX=65536, NCMOE=22, CACHE_MIB=1536, KV=q8_0, PORT=8080, THREADS=8
#   주의(2026-11 기준 이슈): --mmproj(비전) 와 MTP 드래프터를 동시에 켜면 시작 시 abort(#30698) → 둘 중 하나만.
#        MTP 는 MoE 에서 이득이 작거나 없다는 보고(PR #23398 작성자) → 켜고 꺼서 60_bench 로 비교.
# =============================================================================
set -euo pipefail
MODEL="${MODEL:-models/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf}"
DRAFT="${DRAFT:-}"
CTX="${CTX:-65536}"; NCMOE="${NCMOE:-24}"; CACHE_MIB="${CACHE_MIB:-1024}"; KV="${KV:-q8_0}"; PORT="${PORT:-8080}"; THREADS="${THREADS:-8}"   # 32K 이면 NCMOE=22 가능. --fit on 이 넘치면 자동 조정
FIT_TARGET="${FIT_TARGET:-768}"   # Windows 데스크톱이면 1280

ARGS=(-m "$MODEL" --no-mmproj --jinja -fa on -t "$THREADS" -tb "$THREADS"
      -c "$CTX" -ctk "$KV" -ctv "$KV" -b 2048 -ub 512 -np 1
      -ngl all --n-cpu-moe "$NCMOE" --moe-cache-mib "$CACHE_MIB"
      --fit on --fit-target "$FIT_TARGET" --cache-ram 2048
      --spec-default
      --host 127.0.0.1 --port "$PORT")
if [ -n "$DRAFT" ]; then
  ARGS+=(-md "$DRAFT" --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.6 -ctkd "$KV" -ctvd "$KV")
fi
echo "[*] llama-server ${ARGS[*]}"
exec llama-server "${ARGS[@]}"
# 시작 로그 확인: 'KV buffer size', 'n_rot_k/n_rot_v'(Hadamard 회전), 'llama_memory_breakdown_print', 'moe_cache' 적중률
