#!/usr/bin/env bash
# =============================================================================
# 00_build_llamacpp.sh — RTX 50 (Blackwell, sm_120) + Zen 5 전용 llama.cpp 빌드 (Linux / WSL2)
#
#   요구사항: CUDA Toolkit 12.8 이상(13.x 권장), CMake 3.24+, GCC/Clang, git
#   - 120a-real  : Blackwell 전용 네이티브 코드(FP4 텐서코어 커널 포함). CUDA 12.8+ 필수.
#   - GGML_NATIVE : 빌드 머신 CPU(9700X = Zen 5, AVX-512) 명령어 최적화 → MoE 전문가 CPU 오프로드 속도에 직결.
#   - GGML_CUDA_FA_QUANTS=all : K/V 캐시 양자화 조합(q8_0/q4_0/iq4_nl/q5_x 등)을 모두 지원하는 플래시 어텐션 커널.
#
#   Windows 사용자는 scripts/00_build_llamacpp.ps1 (또는 GitHub Releases 의 cuda-13 x64 zip) 참고.
# =============================================================================
set -euo pipefail

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
JOBS="${JOBS:-$(nproc)}"
CUDA_ARCH="${CUDA_ARCH:-120a-real}"        # RTX 5060 Ti = sm_120. 다른 GPU 도 함께 쓰면 "89-real;120a-real" 등
TARGETS=(llama-server llama-cli llama-quantize llama-imatrix llama-perplexity llama-bench llama-gguf-split llama-mtmd-cli)

if ! command -v nvcc >/dev/null 2>&1; then
  echo "[!] nvcc 를 찾을 수 없습니다. CUDA Toolkit 12.8+ 를 설치하고 PATH 에 추가하세요 (예: /usr/local/cuda/bin)." >&2
  exit 1
fi
CUDA_VER=$(nvcc --version | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')
echo "[*] CUDA Toolkit ${CUDA_VER} 감지"
if [ "$(printf '%s\n' "12.8" "$CUDA_VER" | sort -V | head -1)" != "12.8" ]; then
  echo "[!] Blackwell(sm_120)은 CUDA 12.8 이상이 필요합니다. 현재 ${CUDA_VER}." >&2
  exit 1
fi

if [ ! -d "$LLAMA_DIR/.git" ]; then
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi
cd "$LLAMA_DIR"
git pull --ff-only || true

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
  -DGGML_CUDA_FA_QUANTS=all \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=ON \
  -DLLAMA_BUILD_TESTS=OFF

cmake --build build --config Release -j"${JOBS}" --target "${TARGETS[@]}"

echo
echo "[OK] 빌드 완료: ${LLAMA_DIR}/build/bin"
ls -1 "${LLAMA_DIR}/build/bin" | grep -E '^llama-' | sed 's/^/    /'
echo
echo "다음 단계:"
echo "  export PATH=\"${LLAMA_DIR}/build/bin:\$PATH\""
echo "  llama-server --list-devices        # CUDA0 = RTX 5060 Ti 가 보여야 함"
