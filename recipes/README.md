# recipes/ — llama-quantize `--tensor-type-file` 레시피

한 줄에 `정규식=타입` 하나. 텐서 이름은 llama.cpp GGUF 표준 이름(`blk.N.attn_q.weight` 등)이며
정규식은 `regex_search`(부분 일치)로 적용되고, **파일 순서대로 먼저 매치되는 규칙이 적용**됩니다.
`token_embd` / `output` 은 레시피가 아니라 `--token-embedding-type` / `--output-tensor-type` 로 지정합니다.

| 레시피 | 용도 |
|---|---|
| `moe_hybrid_8gb.tensor-types.txt` | MoE 모델(gpt-oss-20b, Gemma 4 26B-A4B, Nemotron 3 Nano 등)을 **전문가=CPU RAM, 어텐션=GPU** 로 돌릴 때. GPU 상주 텐서는 비싸게(q8_0), RAM 상주 전문가는 4비트대로. |
| `dense_gpu_8gb.tensor-types.txt` | 밀집 4~9B 모델을 GPU 에 통째로 올릴 때(IQ4_XS/Q4_K 기반). 민감 텐서(attn_v, ffn_down, 첫/끝 레이어) 보호. |
| `dense_nvfp4_blackwell.tensor-types.txt` | RTX 50 전용 **(실험적)**: 모든 행렬을 **NVFP4(4.5bpw, FP4 텐서코어 네이티브)** 로, 민감 텐서만 q6_k. `GGML_CUDA_MMQ_PREC=q4` 와 함께 쓰면 프리필이 W4A4 FP4 경로로 가속. ※ llama-quantize 의 기본 ftype 목록에는 NVFP4 가 없고(PR #23572 미채택), 이 레시피는 `--tensor-type` 우회 경로(ggml `quantize_nvfp4`, imatrix 지원)를 사용합니다. **공식 경로는 ModelOpt/compressed-tensors NVFP4 체크포인트를 `convert_hf_to_gguf.py` 로 변환**하는 것 → `scripts/45_convert_nvfp4_checkpoint.sh`. 반드시 `scripts/50_eval_kld.sh` 로 KLD 를 확인하세요. |
| `dense_3bit_14b_8gb.tensor-types.txt` | 12~14B 밀집 모델을 8GB 에 억지로 넣을 때(IQ3_M/IQ3_S 기반). 임베딩·출력·attn_v 만 보호. |

타입 이름은 소문자/대문자 모두 허용: `q8_0 q6_k q5_k q4_k iq4_xs iq4_nl mxfp4 nvfp4 iq3_m iq3_s iq3_xxs iq2_m q2_0 q1_0 f16 bf16 ...`
