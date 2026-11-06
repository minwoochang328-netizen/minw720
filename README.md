# 라이젠 7 9700X + RTX 5060 Ti 8GB 로컬 두뇌 설계서 — 영어·한국어 전용, 비중국, 판매 가능 라이선스

> 2026-11-06 기준. 8개 리서치 보고서(하드웨어·모델·한국어·양자화·KV/런타임·실측·법률·비평)와 llama.cpp master 소스(2026-11-04)를 바탕으로 작성하고, **설계 패널(아키텍트 3·심사 3·종합 1)과 적대적 검증(회의론자 10명)으로 다시 확인**했습니다(`docs/08`, `docs/09`). 이 저장소는 **설계 문서 + 재현 가능한 파이프라인(스크립트·레시피·계산기)** 입니다. GPU 가 없는 환경에서 만들어졌으므로 **실제 양자화·추론 수치는 사용자의 PC 에서 처음 측정**됩니다(측정 순서는 §8).

## 0. 결론

**가장 좋은 "두뇌"는 Gemma 4 26B-A4B(Google, Apache-2.0)를 전문가(MoE)만 CPU RAM 에 두고 돌리는 하이브리드 구성**입니다. 8GB GPU 에는 어텐션·공유 MLP·라우터·임베딩·KV 캐시만 올라가고(≈2~5 GiB), 128개 전문가(Q4 ≈ 12 GiB)는 DDR5 에서 토큰마다 ≈ 0.75 GiB 만 읽힙니다. 전문가를 전부 CPU 에 둔 현장 실측은 30 tok/s(RTX 5070 Ti + 7945HX), **9700X 계획치 23~32 tok/s(미측정 — §8 첫 벤치로 보정)**, 컨텍스트 64K~128K. 라이선스는 Apache-2.0 이라 판매에 조건이 없습니다(단 §6 의 미확인 1건 확인 필요).

| 티어 | 모델 (라이선스) | 구성 | 기대 속도 | 왜 |
|---|---|---|---|---|
| **S** | **Gemma 4 26B-A4B-it** (Apache-2.0) | 첫날: 공식 QAT GGUF(Google `-qat-q4_0-gguf` 14.4 GB 또는 Unsloth QAT UD-Q4_K_XL) 그대로. 판매 빌드: QAT 소스에서 전문가 Q4_0(DDR5) + 어텐션·공유 MLP·임베딩 Q8_0(GPU) 14.3 GiB(`recipes/gemma4_26b_a4b_qat_product`), `--n-cpu-moe 24`, q8_0 KV 64K | 23~32 tok/s(추정), pp 450~580 | MMLU-Pro 82.6 / GPQA-D 82.3 / MMMLU 86.3, 256K ctx, 이미지 입력, 가장 풍부한 양자화 생태계(QAT·MTP·EXL3). **심사 3명 전원 1위** |
| **A-1** | **Gemma 4 12B** (Apache-2.0) + 공식 MTP 드래프터 | 8GB **완전 상주**: imatrix A5 혼합 3.97 bpw(`recipes/gemma4_12b_koen_A5`) 또는 EXL3 3.5~4.0 bpw, MTP n_max 2, 16K(Linux 32K) | 27 → **40 tok/s 실측**(RTX 5060 Laptop 8GB), 데스크톱 40~75(추정) | 속도 SKU. 같은 토크나이저·라이선스·한국어 게이트. 한국어 지식 용량은 S 보다 작음(MMLU-Pro 77.2) |
| **A-2** | **Gemma 4 26B-A4B 원본 bf16** — 64 GB RAM 전용 | 전문가 gate/up Q5_K + down **Q8_0**(704 열이라 Q6_K 불가) + imatrix, 19.6 GiB(`recipes/gemma4_26b_a4b_hifi64`) | 20~26 tok/s(추정) | 최고 충실도(KLD ≤ 0.01 급). 32 GB 에선 빠듯 |
| **B** | **한국어 보조**: A.X 3.1 Light 7B (Apache-2.0), Mi:dm 2.0 11.5B (MIT) | A.X: Q4_K_M + q8_0 KV, ctx ≤ 10K / Mi:dm: IQ4_XS 완전 상주, 8K | ~60 / ~50 tok/s | 한국어 기준선·라우팅용(KMMLU 61.7 / Ko-IFEval 82). 영어 추론이 약해 단독 두뇌로는 부족. **S 의 한국어 게이트 기준이 A.X** |
| **B** | **Gemma 4 E4B / E2B** (Apache-2.0) | QAT Q4_0 완전 상주 | 65~87 tok/s | 상시 대기 고속 비서 + 한국어 QLoRA 후보(8 GB 에서 문서상 되는 건 E2B, E4B 는 ≈ 10 GB → 짧은 길이로 시험) |
| **C** | **gpt-oss-20b** (Apache-2.0) | 네이티브 MXFP4 GGUF 그대로, 전문가 16층 CPU, K 캐시 q8_0 유지 | 30~35 tok/s | 영어 추론·도구호출은 강함(AIME-25 91.7), 한국어는 보통(MMMLU-ko 75.7)·한국어 경로 없음 |
| **C** | Granite 4.2 8B (Apache, 공식 NVFP4), Ministral 3 8B (Apache), Nemotron 3.5 Lightning (OpenMDW-1.1) | 완전 상주 / 완전 상주 / 전문가 CPU | 55~85 / 70~85 / 20~30 | FP4 텐서코어 쇼케이스(Granite 토크나이저는 한글 1.4~1.5 tok/음절 → 한국어 속도 절반), Lightning 은 한국어 미지원 |
| **C(내부)** | Kanana-2 30B-A3B (Kanana License) | 전문가 CPU | 25~35 | 한국어 최고(KMMLU 68.3)지만 **재판매 불가** → 내부 벤치마크 천장으로만. 교사/합성데이터로도 쓰지 않음 |
| 제외 | Qwen/DeepSeek/GLM/Kimi 등 중국 모델과 파생(A.X 4.0, OpenReasoning-Nemotron, Hermes 4, GLM-4.5 토크나이저를 쓴 Gravity-30B), EXAONE(NC), Cohere(NC), Mistral Research License 모델, HyperCLOVA X SEED Think 14B(llama.cpp 미지원·9GB) | | | |

영어+한국어만 필요하다는 조건 때문에 **다국어 폭은 평가에서 제외**했고, 한국어는 필수 조건으로 올렸습니다. 글로벌 모델 중 한국어 수치가 공개된 것은 gpt-oss 와 Ministral 뿐이고 **Gemma 4 의 KMMLU 는 아무 곳에도 없으므로** §8 의 측정이 S 티어 확정의 조건입니다.

## 1. 하드웨어가 정해 주는 것 세 가지

1. **디코드는 대역폭이 정합니다.** 5060 Ti 는 448 GB/s, llama.cpp 실효 ≈ 80% → `tok/s ≈ 360 ÷ 토큰당 읽는 GB`. 4.9 GB 모델 ≈ 70 tok/s, 6.2 GB ≈ 55~60. Blackwell FP4 텐서코어는 **프리필(프롬프트 처리)과 배치 검증**만 15~30% 빨라지고 디코드는 그대로입니다.
2. **8 GiB 중 쓸 수 있는 건 Linux ≈ 7.7, Windows 데스크톱 ≈ 7.0 GiB.** 완전 상주 모델은 파일 ≤ ~6.3 GB(KV·드래프터 자리), 그 이상은 MoE 전문가를 RAM 에 두는 하이브리드가 답입니다. Windows 는 NVIDIA 제어판 "CUDA – 시스템 메모리 폴백 정책 → 폴백 없음" 으로 설정해 넘치면 바로 실패하게 하세요(조용히 30% 느려짐 방지).
3. **9700X 는 CCD 1개라 RAM 읽기가 ~64 GB/s 에서 막힙니다**(DDR5-6000 을 꽂아도). 다른 CPU 사례(7945HX·5900X)는 MoE 디코드에서 DRAM 피크의 30~50% 만 썼으므로 9700X 실효는 ≈ 18~32 GB/s 로 봅니다 → Gemma 4 26B-A4B ≈ 23~32 tok/s, gpt-oss-20b ≈ 25~30(모두 미측정). 64GB RAM 은 속도가 아니라 **용량**(더 큰 파일, Q5/Q6 전문가, 두 모델 상주)을 늘립니다. RAM 은 2 DIMM(DDR5-6000 EXPO)으로.

자세한 수치와 스택 비교: `docs/03_하드웨어와_추론스택.md`, 모델 지형도: `docs/04_후보_모델_지형도.md`.

## 2. 추천 구성 상세 (명령은 `scripts/7x_*.sh`, 예산은 `tools/vram_budget.py` 출력)

### 구성 A — "큰 두뇌" Gemma 4 26B-A4B 하이브리드 (`scripts/70_run_gemma4_26b_a4b.sh`)
```bash
llama-server -m gemma-4-26B_q4_0-it.gguf --no-mmproj --jinja -fa on -t 8 -tb 8 \
  -c 65536 -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 -np 1 \
  -ngl all --n-cpu-moe 24 --fit off --cache-ram 2048 --spec-default --temp 1.0 --top-p 0.95 --top-k 64
# Windows 데스크톱: --n-cpu-moe 26 부터. VRAM 을 모르는 PC: -ngl/--n-cpu-moe/--fit off 를 빼고 --fit on --fit-target 1280
```
| 항목 | 값 (계산기, Q4_K_M·attn q8_0·KV q8_0·64K) |
|---|---|
| GPU 가중치 (전문가 6층 포함) | ≈ 4.4 GiB (전문가 전부 CPU 면 1.8 GiB) |
| CPU RAM 전문가 | ≈ 10.3 GiB (전부 CPU 면 12.9 GiB) |
| KV 64K q8_0 | 0.82 GiB (글로벌 5층만 컨텍스트에 비례, 로컬 25층은 윈도우 1024 고정) + 글로벌층(head 512) FA 의 f16 변환 스크래치 ≈ 0.25 GiB |
| GPU 합계 | ≈ 7.0~7.3 GiB → Linux 7.66 GiB 예산 안. **Windows(실사용 ≈ 7.0 GiB)면 `--n-cpu-moe 26`** |
| 디코드 계획치 | 23~32 tok/s, 하한 ≈ 20 (9700X 미측정 — `scripts/60_bench.sh` 로 보정) |

- 파일: 첫날은 `google/gemma-4-26B-A4B-it-qat-q4_0-gguf`(14.4 GB) 또는 `unsloth/gemma-4-26B-A4B-it-qat-GGUF` UD-Q4_K_XL(실측 HumanEvalFix 59/60)을 그대로. 판매용 자체 빌드는 `scripts/40_quantize.sh <qat-unq.gguf> <out> Q4_0 recipes/gemma4_26b_a4b_qat_product.tensor-types.txt [imatrix]`. **⚠ QAT 소스를 llama.cpp RTN Q4_0 으로 바꿔도 QAT 격자는 재현되지 않습니다**(FP16 vs BF16 스케일, Unsloth: E2B KLD 0.051 vs 0.0017) → RTN·imatrix Q4_0·공식 QAT GGUF 를 한/영 KLD 로 비교해 가장 낮은 것을 씁니다(`docs/08` Q1). 범용 `moe_hybrid_8gb` 레시피는 Gemma 4 26B 의 704 열 텐서에서 폴백이 나므로 쓰지 마세요.
- MTP 드래프터(`-md ... --spec-type draft-mtp`)는 MoE + CPU 전문가 조합에서 이득이 불확실(PR 작성자 "이득 없음" vs 8GB 카드 +20% 보고) → `scripts/60_bench.sh` 로 켜고 꺼서 비교. **비전(`--mmproj`)과 MTP 동시 사용은 2026-11 현재 abort(#30698).**
- `--moe-cache-mib` 는 기본 끔: 1 GiB 미만 작은 캐시에서 성능 회귀(#31421), 8GB 카드에서의 이득은 미병합 PR 브랜치 보고뿐 → 1~1.5 GiB 로 A/B 할 때만. `--fit on` 은 명시하지 않은 인자만 조정하므로 `-ngl`/`--n-cpu-moe` 와 같이 쓰면 효과가 없습니다.

### 구성 B — "완전 상주 + MTP" Gemma 4 12B (`scripts/72_run_gemma4_12b_resident.sh`)
- 조건: **48층 전부 GPU**. 파일 ≤ ~6.3 GB → EXL3 3.25 bpw(≈ 4.6 GiB, KLD ≈ 0.04 급) 또는 imatrix IQ3_M + 민감 텐서 보호(`recipes/dense_3bit_14b_8gb`, ≈ 5.4 GiB). 16K q8_0 KV 0.5 GiB + 드래프터 Q6_K.
- 실측(llama.cpp 토론 #25357, RTX 5060 Laptop 8GB): 27.4 → 40.4 tok/s, pp 700~900, 품질 퀴즈 동일. 4~6층만 CPU 로 넘어가면 10~14 tok/s 로 추락 → 파일 크기를 먼저 맞추세요.
- 구조(config.json 확인): 48층 = SWA-1024 40층 + 글로벌 8층, 글로벌 KV 1×512(K=V), vocab 262,144 tied, PLE 없음. 패널 레시피 `recipes/gemma4_12b_koen_A5`(본체 3.97 bpw): Linux 7.32 GiB(+0.34), Windows 는 A5-W(Q4_K 임베딩) + `-ub 256` 6.87 GiB. 상세는 `docs/09` §3.1.

### 구성 C — 한국어 전용 라우트 (`scripts/74_run_kanana2_30b_a3b.sh`, `scripts/75_run_korean_dense.sh`)
| 모델 | 예산(계산기) | 비고 |
|---|---|---|
| Kanana-2 30B-A3B-instruct-2601, IQ4_XS 혼합 | GPU 2.8 GiB + KV 32K 1.8 GiB(MLA 추정) = 5.2 GiB; RAM 13 GiB; ~34 tok/s | llama.cpp PR #19803 지원; 공개 GGUF 미확인 → 직접 변환·양자화; 샘플링 temp 0.6/top_p 0.95/top_k 20, greedy 금지 |
| Mi:dm 2.0 Base-Instruct, IQ4_XS | 7.3 GiB @12K(KV 1.2 GiB) → 통째 상주 | MIT; Ko-IFEval 82, Ko-MTBench 89.7 |
| A.X 3.1 Light, Q4_K_M | 6.6 GiB @8K — **KV 가 272 KiB/token(q8_0)** | MHA(32 KV 헤드) 탓. ctx 8~12K 로 제한 |

### 구성 D — 추론·도구호출용 gpt-oss-20b (`scripts/71_run_gpt_oss_20b.sh`)
- `ggml-org/gpt-oss-20b-GGUF` MXFP4 12.1 GB 를 **그대로**(재양자화 금지, MXFP4 가 학습 정밀도). `--n-cpu-moe 16` + 1 GiB 캐시 + 64K q8_0 KV ≈ 7.0 GiB. 실측 RTX 5060 8GB 33~35 tok/s(단, Unsloth F16 GGUF 로 측정됨 — MXFP4 파일로 재측정 권장).
- K 캐시는 q8_0 이상: q4_0 K 는 AIME25 37.9% → 21.7%(회전 적용 후에도).

## 3. "상상도 못한 양자화 기술" — 이 장비에서 실제로 되는 것

| 기술 | 무엇인가 | 2026-11 상태 | 이 장비에서의 효과 | 적용 방법 |
|---|---|---|---|---|
| **Blackwell FP4 텐서코어 네이티브(W4A4)** | 가중치·활성화 모두 4비트(NVFP4 = E2M1 + 16개당 E4M3 스케일, MXFP4 = 32개당 E8M0)로 `mma.sync` 실행 | llama.cpp 메인라인(MXFP4 2025-12, NVFP4 2026-04). 기본은 정확도 우선 W4A8, `GGML_CUDA_MMQ_PREC=q4` 로 W4A4 강제 | **프리필 +15~30%**, 디코드 불변. W4A4 는 W4A16 용으로 캘리브레이션된 모델에서 KLD +0.02~0.05 | ModelOpt/compressed-tensors NVFP4 체크포인트 → `scripts/45_convert_nvfp4_checkpoint.sh`. **`llama-quantize` 로 NVFP4 를 "만들면" imatrix 를 무시한 RTN(Q4_1 급 품질)** → 실험용만 |
| **학습부터 4비트인 모델** | gpt-oss(전문가 MXFP4 포스트트레이닝), Nemotron 3.5 Lightning(20T+ 토큰 NVFP4 사전학습 + QAD) | 공개 체크포인트 | 양자화 손실이 "정의상 0"(그 정밀도가 기준) | gpt-oss MXFP4 GGUF 그대로; Lightning 은 NVFP4 → GGUF 변환(25 GB, 64GB RAM 권장) |
| **공식 QAT Q4_0 + MTP 드래프터** | 구글이 Q4_0 블록을 겨눠 재학습한 Gemma 4 가중치 + 4층 멀티토큰 예측 헤드 | 전 사이즈 공개(`-qat-q4_0-unquantized`, GGUF 는 unsloth/ggml-org) | 같은 4비트에서 KLD ↓, 밀집 모델 디코드 1.5~2×. **단 QAT-unquantized 를 llama.cpp RTN Q4_0 으로 직접 바꾸면 격자 불일치**(스케일 규칙 차이) → 공식/Unsloth QAT GGUF 를 쓰거나 imatrix Q4_0 과 KLD 비교 | `scripts/72`(12B), `scripts/70`(26B, MTP 는 측정 필요) |
| **EXL3(QTIP 트렐리스)** | Hadamard 회전으로 가우시안화 후 트렐리스 코드로 임의 비트폭 | exllamav3 1.6.6, sm_120 동작, Gemma 4 12B/26B/31B·gpt-oss·Nemotron·Ministral 지원(E2B/E4B 제외) | **비트당 품질 1위**: Llama-3.1-8B KLD 0.053@3.0 bpw, 0.013@4.0(GGUF IQ4_XS 0.023@4.3) → 12B 를 8GB 에 통째로 | `convert.py -b 3.25 -hb 6`; `-cq 8,4` KV; 8GB 에서 12B 변환 가능(≤12B) |
| **imatrix 혼합정밀(UD 방식)** | 한국어+영어+코드 캘리브레이션으로 중요 가중치 측정 → 텐서별 비트폭(`--tensor-type-file`) | llama.cpp 표준 기능 | Q4_K_M KLD 0.031 → 0.028, Q3_K_M 0.102 → 0.084; 전문가 down 투영을 한 단계 올리면 2비트대 오차 40% 감소(NVIDIA 2026-10). 한국어 캘리브레이션의 한국어 이득은 llama.cpp 에서 미측정 → 한국어 KLD 로 확인. 행 길이가 256 배수가 아닌 텐서(Gemma 26B 704/2112)는 K/I-quant 폴백 → `40_quantize.sh` 가 차단 | `calib/build_calibration_set.py` → `scripts/30_imatrix.sh` → `scripts/40_quantize.sh` + `recipes/` |
| **Hadamard 회전 KV 캐시(TurboQuant 의 "절반")** | 양자화 전 K/V 를 Walsh-Hadamard 회전해 이상치 제거 | 메인라인 기본 ON(PR #21038, 2026-04); TurboQuant 전용 turbo 타입은 미채택(포크 TheTom/llama-cpp-turboquant 만) | gpt-oss-20b q4_0 KV AIME25 2.0% → 21.7%, q8_0 31.7 → 37.1(f16 37.9); Qwen3.5-9B q4_0 KLD 0.0080 → 0.0048 | 자동. 끄기 `LLAMA_ATTN_ROT_DISABLE=1`. 릴리스 빌드는 q8_0/q8_0 또는 q4_0/q4_0 만 FA 커널 컴파일 → 비대칭(q8/q4)은 `GGML_CUDA_FA_QUANTS` 자체 빌드(`scripts/00`) |
| **MoE 전문가 GPU 캐시** | CPU 에 둔 전문가 중 자주 쓰는 것을 남는 VRAM 에 LRU/SLRU 캐시 | `--moe-cache-mib`(PR #29887, 2026-10-07) | 4090/5090 에서 1.6~2.2×(적중률 72~89%); 8GB 카드 보고는 PR 브랜치 기준(35 → 62 tok/s, 미병합 #30966) | 1~1.5 GiB 부터(작은 캐시 회귀 #31421), 적중률 로그 확인 |
| **추측 디코딩(MTP·EAGLE-3·n-gram)** | 드래프터가 n 토큰 제안, 본체가 한 번에 검증 | `--spec-type draft-mtp|draft-eagle3|ngram-*`(2026-05/06) | 12B 밀집 1.5×(8GB 실측), 31B 2×; MoE+CPU 전문가는 ~1×(검증 비용) | `--spec-default`(n-gram, 무료)는 항상 켜기 |
| **1비트·삼진** | Q1_0(1.125 bpw, Hadamard 폴딩), TQ1_0/TQ2_0(BitNet) | GGUF 타입 지원 | 속도 폭발적이지만 **비중국 7B+ 네이티브 모델이 없음**(Bonsai 는 Qwen3 계보, BitNet 은 2B) | 기술 관찰. BitNet 2B 는 CPU 상시 비서 정도 |
| **영·한 전용 어휘 트리밍(실험적)** | 262K Gemma 어휘에서 영어·한국어·코드·특수 토큰만 남겨 임베딩/출력 행렬 축소 | 연구(Ushio et al. 2023, vocab-trimmer 류); GGUF 변환 전 HF 단계에서 수행 | 스크립트 규칙 유지 집합 **172,632행**(Gemma 4 실제 어휘로 재확인) → 26B 임베딩 Q8_0 0.73 → 0.48 GiB, 로짓 버퍼 포함 **GPU ≈ −0.42 GiB**(전문가 1층 더 GPU 로); 12B 는 Windows 여유 +0.27; E4B PLE 1.48 → 0.97 GiB | 특수 토큰·바이트 폴백·MTP 드래프터 임베딩까지 같은 슬라이스, 토큰화 동일성 테스트, 트림-대-트림 KLD. 절차 `docs/09` §5.1, 코드는 후속. 출시본은 OFF(실험판) |

상세: `docs/05_양자화_기술_총정리.md`(가중치), `docs/06_KV캐시_런타임_실측.md`(KV·오프로드·실측·함정).

## 4. 파이프라인 (요약; 전체는 `docs/02_파이프라인_사용법.md`)

1. **빌드**: `scripts/00_build_llamacpp.sh`(CUDA ≥ 12.8, `120a-real`, `GGML_CUDA_FA_QUANTS=all`). Windows 는 Releases 의 **`cuda-13.x` zip**(`cuda-12.4` zip 은 sm_120 커널 없음) 또는 `00_build_llamacpp.ps1`.
2. **다운로드**: `scripts/10_download.sh`.
3. **캘리브레이션 + imatrix**: `calib/build_calibration_set.py`(한 40/영 35/코드 15/대화 10) → `scripts/30_imatrix.sh`(MoE 는 자동 `--cpu-moe`).
4. **혼합정밀 양자화**: `scripts/40_quantize.sh <in> <out> <ftype> recipes/<레시피> <imatrix>`.
5. **품질 게이트**: `scripts/50_eval_kld.sh` — 평균 KLD **< 0.03 무손실급, 0.03~0.06 양호, > 0.1 체감**. 한국어 held-out 텍스트로 따로 측정.
6. **속도**: `scripts/60_bench.sh <gguf> "24,16,12" "q8_0"`.
7. **서빙**: `scripts/70~75`. 시작 로그에서 `offloaded N/N layers`, `KV buffer size`, `n_rot_k/n_rot_v`, `moe_cache` 적중률 확인.
8. **예산 예측**: `python3 tools/vram_budget.py --model gemma-4-26b-a4b --quant q4_k_m --quant-attn q8_0 --kv q8_0 --ctx 65536 --n-cpu-moe 24` (`--os windows` 로 예약 메모리 반영, `--sweep` 로 전체 비교).

## 5. 영어·한국어 전략

- **측정이 먼저**: Gemma 4 는 한국어 수치가 없으므로 KMMLU 일부(또는 CLIcK/HAE-RAE)와 한국어 KLD 를 `50_eval_kld.sh` 로 재고, 미달이면 한국어 응대는 B 티어(A.X 3.1 Light / Mi:dm 2.0) 라우트로 보냅니다. 글로벌 ≤30B 모델은 KMMLU-Pro 45~51 vs 한국 30B 급 67~69 입니다.
- **토크나이저**: Kanana-2/A.X/Mi:dm 는 같은 한국어에 Gemma(262K SP)·o200k 보다 1.3~1.5× 적은 토큰 → 같은 tok/s 에서 글자/초가 높고 KV 도 덜 씁니다. `llama-tokenize -m model.gguf -f korean.txt | wc -l` 로 비교.
- **캘리브레이션·평가에 한국어 비중 유지**(비라틴 문자는 양자화 손상이 더 큼). **imatrix 는 "어떤 텍스트냐"보다 "쓰느냐"가 훨씬 중요**하지만, 한국어가 전혀 없으면 한국어 경로가 먼저 깨집니다.
- **파인튜닝**: 8GB QLoRA 는 소형만. Unsloth 문서상 Gemma 4 는 **E2B 만 8 GB, E4B 는 ≈ 10 GB**(8 GB 에선 max_seq 512~1K·r 8·배치 1 로 시험). 26B-A4B 는 QLoRA 비권장·16비트 LoRA > 40 GB → 임대 A100/H100. 7~8B 밀집(A.X 3.1 Light, Ministral 3 8B, Granite 4.2 8B)은 짧은 길이 QLoRA 를 시험해 볼 만함. QAT 는 ≤3B. Kanana 출력·가중치는 학습에 쓰지 않습니다(결과물이 Kanana 파생물이 됨). "QAT-unquantized 체크포인트 + LoRA → 같은 Q4_0 재양자화" 레시피와 상업 이용 가능한 한국어 데이터 목록은 `docs/07_한국어모델_라이선스_파인튜닝.md`.

## 6. 판매 체크리스트

| 모델 | 라이선스 | 해야 할 것 |
|---|---|---|
| Gemma 4(전 사이즈, QAT 포함) | Apache-2.0 | LICENSE 사본·NOTICE·수정 고지; "Gemma" 를 제품 브랜드로 쓰지 않기. **HF 카드가 가리키는 `ai.google.dev/gemma/docs/gemma_4_license` 페이지 원문을 아무도 읽지 못했음 → 출시 전 확인(금지사용 전가 조항 여부)** |
| gpt-oss-20b | Apache-2.0 + USAGE_POLICY("적용 법률 준수" 1문장) | 위와 동일 + USAGE_POLICY 파일 유지 |
| Mi:dm 2.0 / Phi-4 / BitNet | MIT | 저작권·허가 고지 |
| A.X 3.1 Light, Kanana-1.5, Ministral 3, Granite 4.x, OLMo 3 | Apache-2.0 | LICENSE/NOTICE |
| Kanana-2 | Kanana License(원문 확인) | 자사 서비스 내부 사용은 가능(§4.3; 책임 AI 가이드라인 전가·"Powered by Kanana"·NOTICE 의무). **API/클라우드·SI/온프렘·디바이스 탑재 재판매는 카카오 재량의 별도 계약**(§4.1, §4.4; alpha.k@kakaocorp.com). §4.2 는 출시일(2025-07-17) 기준 MAU 1천만 초과 여부 1회 테스트. 학습은 허용되나 결과 모델은 Kanana 파생물(재판매 제한·"Kanana" 이름 접두) |
| Nemotron 3 Nano | NVIDIA Nemotron Open Model License(2025-12) | NOTICE 문구; 어느 텍스트가 HF 저장소를 지배하는지(가드레일 조항 유무) 미확정 |
| Nemotron 3.5 Lightning, Trinity | OpenMDW-1.1 | 계약서 사본 + 고지 |
| LFM2/2.5 | LFM Open License | **연매출 < US$10M** 만 |
| Llama 3.x | Llama Community | "Built with Llama", 이름 접두, AUP 전가, MAU 7억 |
| 모든 제품(한국) | AI 기본법 §31(2026-01-22 시행, 계도기간 ≥1년) | 생성형 AI 사용 사전 고지, 출력 "AI 생성" 표시(기계판독 + 1회 안내 가능), 합성 미디어 라벨, 고영향 영역 점검, 학습데이터 출처 고지 |

## 7. 저장소 구조

```
README.md                      ← 이 문서(결론·구성·기술·체크리스트)
docs/02_파이프라인_사용법.md     빌드→변환→imatrix→양자화→KLD→벤치→서빙
docs/03_하드웨어와_추론스택.md   5060 Ti/9700X 사실, llama.cpp·vLLM·EXL3 상태, GGUF 타입
docs/04_후보_모델_지형도.md      비중국·판매가능 후보 전체 표, 라이선스 매트릭스, 순위
docs/05_양자화_기술_총정리.md    NVFP4/MXFP4/EXL3/GGUF/QAT/연구급 PTQ/MoE 혼합정밀(60KB)
docs/06_KV캐시_런타임_실측.md    TurboQuant 실체, KV 예산표, 전문가 오프로드, 추측 디코딩, 실측·함정(74KB)
docs/07_한국어모델_라이선스_파인튜닝.md  한국 모델, 판매 라이선스 원문 요지, 8GB 파인튠/QAT, 데이터 라이선스, AI 기본법
docs/08_설계패널_검증.md         설계 패널 3안·심사 점수·회의론자 16개 주장 판정과 정정
docs/09_최종계획_설계패널.md      최종 계획(티어·레시피·게이트 G0~G8·시간표·재판매 체크리스트), 검증 정정 반영
tools/vram_budget.py, presets.json, test_vram_budget.py   예산·속도 계산기(검증된 구조 수치 + 패널 보정 프리셋, 테스트 8/8)
scripts/00~10  빌드(Linux/Windows)·다운로드      scripts/30~60  imatrix·양자화·NVFP4 변환·KLD·벤치
scripts/70~75  모델별 llama-server 실행           recipes/  텐서별 양자화 레시피(Gemma 4 26B S/HiFi64·12B A5, MoE 하이브리드·밀집·NVFP4·3비트)
calib/build_calibration_set.py  한·영·코드·대화 캘리브레이션 세트 생성기
```

## 8. 실제 PC 에서 먼저 측정할 것 (순서대로)

1. `nvidia-smi` 로 유휴 VRAM 사용량(Windows 데스크톱 예약) 확인 → `--fit-target` 결정.
2. `llama-bench -m <gemma-4-26B-A4B QAT> -ngl 99 -ncmoe 30,24,20,16 -fa 1 -ctk q8_0 -ctv q8_0 -d 8192` (`scripts/60_bench.sh`) → 전문가 몇 층을 GPU 에 남길지. 9700X 의 실측 CPU 디코드가 이 문서의 모든 추정을 보정합니다.
3. 같은 모델에 `--moe-cache-mib 0,1024,1536` 과 MTP 드래프터 on/off.
4. `scripts/50_eval_kld.sh` 로 S 후보 KLD(영어·한국어 각각): 공식 QAT GGUF / Unsloth QAT UD-Q4_K_XL / 자체 RTN Q4_0 / 자체 imatrix Q4_0 → 가장 낮은 것을 출시 파일로.
5. 한국어 게이트(`docs/09` §6): KMMLU 층화 900문 + HAE-RAE + Ko-IFEval 로 Gemma 4 26B-A4B 가 **A.X 3.1 Light 이상**인지(같은 하네스), 한글 충실도 200문. Kanana-2 는 내부 천장 참고용.
6. Gemma 4 12B 완전 상주 구성: 파일 ≤ 6.3 GB 확인 후 MTP n_max 2 로 tok/s.

## 9. 미확인 사항과 위험 (비평 보고서 기준)

- Gemma 4 라이선스 페이지(`ai.google.dev/gemma/docs/gemma_4_license`) 원문 — HF 저장소 63개 모두 apache-2.0·게이트 없음으로 강하게 지지되지만 원문 미열람(이 세션 네트워크에서 차단). 판매 전 원문 보관.
- Gemma 4 의 한국어 벤치 수치 0개 → §8-5 게이트가 S 티어 확정 조건.
- 자체 Q4_0 빌드가 공식 QAT GGUF 만큼 좋은지(§8-4).
- 8 GB 에서 E4B QLoRA 가 실제로 도는지.
- Kanana-2 사전학습 계보(from scratch 여부 미기재), 공개 GGUF.
- Nemotron 3 Nano 지배 라이선스 텍스트; Nemotron 3.5 Lightning 포스트트레이닝 데이터 출처.
- 9700X + DDR5 에서의 MoE 하이브리드 실측치 없음(모든 tok/s 는 다른 CPU 보고를 보정한 추정). 4060 Ti 8GB 29.3 tok/s 는 출처 미확인, "Ollama 4.5 vs llama.cpp 25" 는 Radeon 780M iGPU 사례.
- 쓸 수 있는 VRAM 7.22/7.66 GiB 는 계산기 가정치 → 첫 실행에서 `llama_memory_breakdown_print`·`nvidia-smi` 로 확인.
- LM Studio/Ollama 번들 런타임의 `120a` 컴파일·NVFP4 GGUF 로딩 여부 미문서 → llama.cpp 직접 사용 권장.
- 2026-11 열린 버그: Gemma 4 `--mmproj`+MTP abort(#30698), E4B MTP+`--kv-unified`(#31482), 작은 `--moe-cache-mib` 회귀(#31421), CUDA 13.2.0/13.2.1 의 IQ1/2/3_S 미컴파일(13.2.86+ 사용), sm_120 CUDA 그래프 행(`GGML_CUDA_DISABLE_GRAPHS=1`).
- 이 문서의 수치 중 [L] 표시(단일 블로그·추정)는 부록에서 그대로 표시했습니다. 적대적 검증 결과(16개 주장: 확인 4·반박 6·보류 6)와 정정 내역은 `docs/08_설계패널_검증.md`.
