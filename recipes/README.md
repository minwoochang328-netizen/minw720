# recipes/ — llama-quantize `--tensor-type-file` 레시피

한 줄에 `정규식=타입` 하나. 텐서 이름은 llama.cpp GGUF 표준 이름(`blk.N.attn_q.weight` 등)이며
정규식은 `regex_search`(부분 일치)로 적용되고, **파일 순서대로 먼저 매치되는 규칙이 적용**됩니다.
`token_embd` / `output` 은 레시피가 아니라 `--token-embedding-type` / `--output-tensor-type` 로 지정합니다.

| 레시피 | 용도 |
|---|---|
| `moe_hybrid_8gb.tensor-types.txt` | MoE 모델(Gemma 4 26B-A4B, Nemotron 3 Nano/3.5 Lightning, Kanana-2 30B-A3B 등)을 **전문가=CPU RAM, 어텐션=GPU** 로 돌릴 때의 **품질 우선** 기본값. GPU 상주 텐서는 q8_0, 전문가 up/gate 는 IQ4_XS(imatrix), down 은 한 단계 위 Q5_K. gpt-oss-20b 는 네이티브 MXFP4 를 그대로 두는 것이 정답(재양자화 금지). |
| `moe_hybrid_8gb_fast.tensor-types.txt` | 같은 구성의 **속도 우선** 변형(전문가 IQ3_S/IQ4_XS). RAM 대역폭이 디코드 속도를 정하므로 ~19% 빠르지만 KLD 는 약 3배. |
| `dense_gpu_8gb.tensor-types.txt` | 밀집 4~9B 모델을 GPU 에 통째로 올릴 때(IQ4_XS/Q4_K 기반). 민감 텐서(attn_v, ffn_down, 첫/끝 레이어) 보호. |
| `dense_nvfp4_blackwell.tensor-types.txt` | RTX 50 전용 **(실험적)**: 모든 행렬을 **NVFP4(4.5bpw, FP4 텐서코어 네이티브)** 로, 민감 텐서만 q6_k. `GGML_CUDA_MMQ_PREC=q4` 와 함께 쓰면 프리필이 W4A4 FP4 경로로 가속. ※ llama-quantize 의 기본 ftype 목록에는 NVFP4 가 없고(PR #23572 미채택), 이 레시피는 `--tensor-type` 우회 경로(ggml `quantize_nvfp4`, imatrix 지원)를 사용합니다. **공식 경로는 ModelOpt/compressed-tensors NVFP4 체크포인트를 `convert_hf_to_gguf.py` 로 변환**하는 것 → `scripts/45_convert_nvfp4_checkpoint.sh`. 반드시 `scripts/50_eval_kld.sh` 로 KLD 를 확인하세요. |
| `dense_3bit_14b_8gb.tensor-types.txt` | 12~14B 밀집 모델을 8GB 에 억지로 넣을 때(IQ3_M/IQ3_S 기반). 임베딩·출력·attn_v 만 보호. |

⚠ **mxfp4 / nvfp4 는 `llama-quantize` 에서 imatrix 를 무시하는 RTN(round-to-nearest) 양자화**입니다(ggml-quants.c `GGML_UNUSED(quant_weights)`). 품질은 Q4_0/Q4_1 급 → 네이티브 MXFP4 모델(gpt-oss)이나 ModelOpt 로 캘리브레이션된 NVFP4 체크포인트 변환에만 쓰고, 일반 모델의 재양자화에는 imatrix 가 적용되는 IQ4_XS/Q4_K/Q5_K 를 쓰세요.

타입 이름은 소문자/대문자 모두 허용: `q8_0 q6_k q5_k q4_k iq4_xs iq4_nl mxfp4 nvfp4 iq3_m iq3_s iq3_xxs iq2_m q2_0 q1_0 f16 bf16 ...`
