# =============================================================================
# 00_build_llamacpp.ps1 — Windows 11 에서 RTX 50(sm_120) 용 llama.cpp 준비
#
# 방법 A (권장, 가장 쉬움): GitHub Releases 프리빌드 사용
#   https://github.com/ggml-org/llama.cpp/releases 에서
#     llama-bXXXX-bin-win-cuda-13.x-x64.zip   (또는 cuda-12.8+ 표기 zip)
#     cudart-llama-bin-win-cuda-13.x-x64.zip  (CUDA 런타임 DLL; 드라이버만 있으면 됨)
#   두 zip 을 같은 폴더에 풀면 끝. (NVIDIA 드라이버는 CUDA 13 지원 버전으로 최신화)
#
# 방법 B: 직접 빌드 (Visual Studio 2022 + "C++ 데스크톱 개발" + CUDA Toolkit 12.8/13.x 설치 후)
#   아래 스크립트를 "x64 Native Tools Command Prompt" 또는 PowerShell(VS 환경 로드됨)에서 실행
# =============================================================================
$ErrorActionPreference = "Stop"
$LlamaDir = if ($env:LLAMA_DIR) { $env:LLAMA_DIR } else { "$HOME\llama.cpp" }
$CudaArch = if ($env:CUDA_ARCH) { $env:CUDA_ARCH } else { "120a-real" }

if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) {
  Write-Error "nvcc 를 찾을 수 없습니다. CUDA Toolkit 12.8+ 를 설치하세요. (프리빌드를 쓰려면 방법 A 참고)"
}
if (-not (Test-Path "$LlamaDir\.git")) {
  git clone --depth 1 https://github.com/ggml-org/llama.cpp $LlamaDir
}
Set-Location $LlamaDir
git pull --ff-only

cmake -B build -G "Visual Studio 17 2022" -A x64 `
  -DGGML_CUDA=ON `
  -DCMAKE_CUDA_ARCHITECTURES="$CudaArch" `
  -DGGML_CUDA_FA_QUANTS=all `
  -DGGML_NATIVE=ON `
  -DLLAMA_CURL=ON `
  -DLLAMA_BUILD_TESTS=OFF
cmake --build build --config Release -j --target llama-server llama-cli llama-quantize llama-imatrix llama-perplexity llama-bench llama-gguf-split llama-mtmd-cli

Write-Host "`n[OK] 빌드 완료: $LlamaDir\build\bin\Release"
Write-Host "환경변수 PATH 에 위 경로를 추가한 뒤  llama-server --list-devices  로 CUDA0 확인"
