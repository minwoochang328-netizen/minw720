#!/usr/bin/env python3
"""
vram_budget.py — VRAM / RAM / 컨텍스트 예산 계산기 (단일 소비자 GPU + CPU 하이브리드 추론)

기본 타깃: NVIDIA RTX 5060 Ti 8 GiB + AMD Ryzen 7 9700X (DDR5 듀얼채널)

순수 파이썬(의존성 없음). 모델 프리셋은 같은 폴더의 presets.json 에 있습니다.

핵심 질문에 답합니다:
  1. 이 모델을 이 비트폭(양자화)으로, 이 컨텍스트에서, 전문가(MoE) N개 레이어를 CPU로 보내면
     GPU 메모리에 들어가는가? (가중치 + KV 캐시 + 연산 버퍼 + CUDA 컨텍스트)
  2. 메모리 대역폭 기준 디코드(토큰 생성) 속도 상한은 얼마인가?

사용 예:
  python tools/vram_budget.py --list
  python tools/vram_budget.py --model gpt-oss-20b --quant mxfp4 --kv q8_0 --ctx 32768 --n-cpu-moe 24
  python tools/vram_budget.py --model llama-3.1-8b --quant Q4_K_M --ctx 16384
  python tools/vram_budget.py --sweep --ctx 16384            # 모든 프리셋 비교표
  python tools/vram_budget.py --model gpt-oss-20b --quant mxfp4 --ctx 32768 --n-cpu-moe 24 --json

주의: 추정치입니다. llama.cpp 의 `--fit-print on`, nvidia-smi 로 실제 값을 확인하세요.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass, field, asdict
from typing import Optional

MiB = 1024 ** 2
GiB = 1024 ** 3

# ---------------------------------------------------------------------------
# 1. 양자화 포맷 → 평균 bits/weight (파일 수준 평균, llama.cpp/EXL3/HF 기준)
# ---------------------------------------------------------------------------
# GGUF 값은 llama-quantize 의 공식 설명/실측(Llama-3-8B)에서, 포맷 값은 블록 구조에서 계산.
#   MXFP4 : 32개 E2M1(4bit) + 1개 E8M0 스케일(8bit)            → 4.25 bpw
#   NVFP4 : 64개 E2M1 + 4개 UE4M3 스케일(16개당 1개) (+텐서 FP32) → 4.50 bpw
#   Q8_0  : 32개 int8 + f16 스케일                               → 8.50 bpw
#   Q4_0  : 32개 int4 + f16 스케일                               → 4.50 bpw
BPW = {
    "f32": 32.0, "f16": 16.0, "bf16": 16.0,
    "q8_0": 8.5, "q6_k": 6.5625, "q5_k_m": 5.69, "q5_k_s": 5.52, "q5_0": 5.5, "q5_1": 6.0,
    "q4_k_m": 4.85, "q4_k_s": 4.58, "q4_k": 4.5, "q4_0": 4.5, "q4_1": 5.0, "iq4_nl": 4.5, "iq4_xs": 4.25,
    "mxfp4": 4.25, "nvfp4": 4.5,
    "q3_k_l": 4.27, "q3_k_m": 3.91, "q3_k_s": 3.5, "iq3_m": 3.66, "iq3_s": 3.44, "iq3_xs": 3.3, "iq3_xxs": 3.06,
    "q2_k": 3.16, "q2_k_s": 2.96, "iq2_m": 2.7, "iq2_s": 2.5, "iq2_xs": 2.31, "iq2_xxs": 2.06, "q2_0": 2.25,
    "iq1_m": 1.75, "iq1_s": 1.56, "tq2_0": 2.06, "tq1_0": 1.69, "q1_0": 1.125,
    # EXL3 (exllamav3) 임의 bpw: "exl3-3.0" 처럼 숫자를 직접 쓰면 됨 (헤더 오버헤드 ~+0.03)
}

# KV 캐시 셀 타입 → bits/element
KV_BITS = {
    "f32": 32.0, "f16": 16.0, "bf16": 16.0,
    "q8_0": 8.5, "q5_1": 6.0, "q5_0": 5.5, "q4_1": 5.0, "q4_0": 4.5, "iq4_nl": 4.5,
    # TurboQuant 전용 타입(tbq3_0/tbq4_0, PR #21089)은 llama.cpp 메인라인에 머지되지 않았음(2026-06 종결).
    # 메인라인은 대신 K/V 를 양자화 전에 Hadamard 회전(PR #21038, 2026-04, 기본 ON)하여 q4_0 KV 품질을 크게 개선.
    # 아래 turbo* 값은 포크(TheTom/turboquant_plus 등) 사용 시의 참고용.
    "turbo4": 4.5, "turbo3": 3.5, "turbo2": 2.5,
    # vLLM / exllamav3
    "fp8": 8.0, "exl3-q4": 4.25, "exl3-q6": 6.25,
}


def bpw_of(name: str) -> float:
    n = name.lower()
    if n in BPW:
        return BPW[n]
    if n.startswith("exl3-"):
        return float(n.split("-", 1)[1]) + 0.03
    try:
        return float(n)  # 숫자를 직접 준 경우
    except ValueError:
        raise SystemExit(f"알 수 없는 양자화 포맷: {name}. 사용 가능: {', '.join(sorted(BPW))}, exl3-<bpw>, <숫자>")


def kv_bits_of(name: str) -> float:
    n = name.lower()
    if n in KV_BITS:
        return KV_BITS[n]
    try:
        return float(n)
    except ValueError:
        raise SystemExit(f"알 수 없는 KV 타입: {name}. 사용 가능: {', '.join(sorted(KV_BITS))}")


# ---------------------------------------------------------------------------
# 2. 모델 사양
# ---------------------------------------------------------------------------
@dataclass
class ModelSpec:
    name: str
    org: str = ""
    country: str = ""
    license: str = ""
    release: str = ""
    verified: bool = False           # 프리셋 수치가 1차 자료로 검증되었는지
    notes: str = ""

    # 트랜스포머 구조
    n_layer: int = 0
    n_attn_layer: Optional[int] = None   # 하이브리드(Mamba 등)에서 어텐션 레이어 수. None = n_layer
    n_head_kv: int = 0
    head_dim: int = 0
    n_embd: int = 0
    vocab: int = 0
    tied_embeddings: bool = False
    # 슬라이딩 윈도우(로컬) 어텐션: 해당 레이어 수와 윈도우 크기 (Gemma, gpt-oss 등)
    n_swa_layer: int = 0
    swa_window: int = 0
    # SSM(Mamba) 고정 상태 크기 (시퀀스당, MiB) — 하이브리드 모델용
    ssm_state_mib: float = 0.0

    # 파라미터(단위: 10억 개). params_total = experts + ffn_dense + attn_other + embed(+output)
    params_total_b: float = 0.0
    params_active_b: float = 0.0
    params_experts_b: float = 0.0        # 모든 MoE 전문가 가중치 합
    params_experts_active_b: float = 0.0 # 토큰당 활성 전문가 가중치 합
    params_ffn_dense_b: float = 0.0      # 밀집 FFN(공유 전문가 포함) 합
    params_embed_b: float = 0.0          # 입력 임베딩
    params_output_b: float = 0.0         # 출력(lm_head). tied 이면 0
    # 추가 고정 메모리(예: Gemma PLE 임베딩, 비전 타워), GiB
    extra_fixed_gib: float = 0.0

    @property
    def params_attn_other_b(self) -> float:
        return max(0.0, self.params_total_b - self.params_experts_b - self.params_ffn_dense_b
                   - self.params_embed_b - self.params_output_b)

    @property
    def n_full_layer(self) -> int:
        n_attn = self.n_attn_layer if self.n_attn_layer is not None else self.n_layer
        return max(0, n_attn - self.n_swa_layer)


@dataclass
class Hardware:
    gpu_name: str = "RTX 5060 Ti 8GB"
    gpu_vram_gib: float = 8.0
    gpu_bw_gbs: float = 448.0            # GDDR7 28 Gbps × 128-bit
    gpu_bw_eff: float = 0.78             # 디코드 시 실효 대역폭 비율(경험값)
    cpu_name: str = "Ryzen 7 9700X"
    # 9700X 는 CCD 1개 → Infinity Fabric 읽기 상한 ≈ 64 GB/s (32B/clk × FCLK 2.0GHz). DDR5-6000 의 96 GB/s 를 다 못 씀.
    # AIDA64 실측 ≈ 52 GB/s(stock). 듀얼 CCD(9900X/9950X)면 --ram-bw 90 정도로 올려서 계산.
    cpu_bw_gbs: float = 64.0
    cpu_bw_eff: float = 0.85             # llama.cpp CPU MoE 디코드 실효 비율 → ≈ 54 GB/s
    os: str = "linux"                    # linux | windows
    per_token_overhead_ms: float = 1.5   # 커널 런치/동기화/CPU↔GPU 왕복 등 고정 비용(오프로드 시 증가)

    @property
    def os_reserve_mib(self) -> float:
        # 윈도우 WDDM + 데스크톱 합성기, 모니터가 이 GPU에 연결된 경우 더 큼
        return 350.0 if self.os == "linux" else 800.0


@dataclass
class Plan:
    quant: str = "q4_k_m"            # 전문가/FFN/어텐션 기본 비트폭
    quant_attn: Optional[str] = None # 어텐션/기타 텐서(기본: quant 보다 한 단계 높은 정밀도가 보통 유리)
    quant_embed: Optional[str] = None
    quant_output: Optional[str] = None
    kv_k: str = "f16"
    kv_v: str = "f16"
    ctx: int = 8192
    n_cpu_moe: int = 0               # 전문가 가중치를 CPU에 두는 레이어 수 (llama.cpp --n-cpu-moe N)
    n_cpu_ffn: int = 0               # 밀집 FFN 을 CPU에 두는 레이어 수 (llama.cpp --n-cpu-ffn N)
    ubatch: int = 512
    swa_full: bool = False           # llama.cpp --swa-full (SWA 레이어도 전체 컨텍스트 캐시)
    n_parallel: int = 1
    moe_cache_mib: int = 0           # llama.cpp --moe-cache-mib N : CPU 에 둔 전문가 중 자주 쓰는 것을 GPU 에 캐시
    moe_cache_hit: float = 0.5       # 캐시 적중률 가정(0~1). 실측으로 보정하세요


@dataclass
class Budget:
    model: str
    plan: dict
    # 가중치
    weights_gpu_gib: float
    weights_cpu_gib: float
    weights_total_gib: float
    file_size_gib: float
    # 런타임
    kv_gib: float
    kv_bytes_per_token_full: float
    compute_buf_gib: float
    cuda_ctx_gib: float
    os_reserve_gib: float
    extra_fixed_gib: float
    moe_cache_gib: float
    gpu_total_gib: float
    gpu_budget_gib: float
    fits: bool
    headroom_gib: float
    max_ctx_fit: int
    # 속도 추정
    decode_tps_ceiling: float
    decode_tps_realistic: float
    gpu_bytes_per_token: float
    cpu_bytes_per_token: float
    prefill_tps_rough: float
    notes: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# 3. 계산
# ---------------------------------------------------------------------------
def kv_bytes_per_token(m: ModelSpec, plan: Plan) -> float:
    """풀 어텐션 레이어 1개, 토큰 1개당 K+V 바이트 (레이어 수 포함 전).
    K 와 V 는 각각 n_head_kv × head_dim 원소."""
    per_layer = m.n_head_kv * m.head_dim * (kv_bits_of(plan.kv_k) + kv_bits_of(plan.kv_v)) / 8.0
    return per_layer


def kv_total_bytes(m: ModelSpec, plan: Plan) -> float:
    per_layer_tok = kv_bytes_per_token(m, plan)
    ctx = plan.ctx * plan.n_parallel
    full = m.n_full_layer * ctx * per_layer_tok
    if m.n_swa_layer:
        swa_tokens = ctx if plan.swa_full else min(ctx, m.swa_window + plan.ubatch)  # llama.cpp SWA 캐시는 윈도우+ubatch 패딩
        full += m.n_swa_layer * swa_tokens * per_layer_tok
    full += m.ssm_state_mib * MiB * plan.n_parallel
    return full


def weights_split(m: ModelSpec, plan: Plan):
    """(gpu_bytes, cpu_bytes, file_bytes) 반환."""
    b = bpw_of(plan.quant) / 8.0
    b_attn = bpw_of(plan.quant_attn) / 8.0 if plan.quant_attn else b
    b_emb = bpw_of(plan.quant_embed) / 8.0 if plan.quant_embed else b
    b_out = bpw_of(plan.quant_output) / 8.0 if plan.quant_output else b
    B = 1e9
    experts = m.params_experts_b * B * b
    ffn = m.params_ffn_dense_b * B * b
    attn = m.params_attn_other_b * B * b_attn
    emb = m.params_embed_b * B * b_emb
    out = m.params_output_b * B * b_out
    file_bytes = experts + ffn + attn + emb + out

    n_layer = max(1, m.n_layer)
    frac_moe_cpu = min(1.0, plan.n_cpu_moe / n_layer) if m.params_experts_b else 0.0
    frac_ffn_cpu = min(1.0, plan.n_cpu_ffn / n_layer) if m.params_ffn_dense_b else 0.0
    cpu = experts * frac_moe_cpu + ffn * frac_ffn_cpu
    # 입력 임베딩(token_embd)은 llama.cpp 에서 보통 CPU(호스트) 버퍼에 둔다 → GPU 에서 제외
    gpu = file_bytes - cpu - emb
    return gpu, cpu, file_bytes, dict(experts=experts, ffn=ffn, attn=attn, emb=emb, out=out,
                                      frac_moe_cpu=frac_moe_cpu, frac_ffn_cpu=frac_ffn_cpu)


def compute_buffer_bytes(m: ModelSpec, plan: Plan) -> float:
    """llama.cpp CUDA 연산 버퍼 대략치(플래시 어텐션 ON 가정). ±30%."""
    ffn_used = 0.0
    if m.params_experts_b and m.n_layer:
        # 토큰당 활성 전문가 중간 차원 추정: 활성 전문가 파라미터/레이어/3행렬/n_embd
        ffn_used = (m.params_experts_active_b * 1e9 / m.n_layer) / 3.0 / max(1, m.n_embd)
    elif m.params_ffn_dense_b and m.n_layer:
        ffn_used = (m.params_ffn_dense_b * 1e9 / m.n_layer) / 3.0 / max(1, m.n_embd)
    per_tok = (m.n_embd * 4 + ffn_used * 2 + m.vocab) * 4.0
    return 64 * MiB + plan.ubatch * per_tok


def estimate(m: ModelSpec, hw: Hardware, plan: Plan) -> Budget:
    notes = []
    gpu_w, cpu_w, file_w, parts = weights_split(m, plan)
    kv = kv_total_bytes(m, plan)
    cbuf = compute_buffer_bytes(m, plan)
    cuda_ctx = 300 * MiB
    extra = m.extra_fixed_gib * GiB
    moe_cache = plan.moe_cache_mib * MiB if (m.params_experts_b and plan.n_cpu_moe > 0) else 0.0
    gpu_total = gpu_w + kv + cbuf + cuda_ctx + extra + moe_cache
    budget = hw.gpu_vram_gib * GiB - hw.os_reserve_mib * MiB
    fits = gpu_total <= budget
    headroom = budget - gpu_total

    # 현재 설정에서 KV 로 더 늘릴 수 있는 최대 컨텍스트 (이진 탐색)
    lo, hi = 0, 2_000_000
    base_no_kv = gpu_w + cbuf + cuda_ctx + extra + moe_cache
    if base_no_kv > budget:
        max_ctx = 0
    else:
        while lo < hi:
            mid = (lo + hi + 1) // 2
            p2 = Plan(**{**asdict(plan), "ctx": mid})
            if base_no_kv + kv_total_bytes(m, p2) <= budget:
                lo = mid
            else:
                hi = mid - 1
        max_ctx = lo

    # 디코드 속도: 토큰당 읽어야 하는 바이트 / 대역폭
    b = bpw_of(plan.quant) / 8.0
    b_attn = bpw_of(plan.quant_attn) / 8.0 if plan.quant_attn else b
    b_out = bpw_of(plan.quant_output) / 8.0 if plan.quant_output else b
    B = 1e9
    active_experts_bytes = m.params_experts_active_b * B * b
    hit = plan.moe_cache_hit if moe_cache > 0 else 0.0
    cpu_bytes = active_experts_bytes * parts["frac_moe_cpu"] * (1 - hit) + m.params_ffn_dense_b * B * b * parts["frac_ffn_cpu"]
    gpu_bytes = (active_experts_bytes * (1 - parts["frac_moe_cpu"]) + active_experts_bytes * parts["frac_moe_cpu"] * hit
                 + m.params_ffn_dense_b * B * b * (1 - parts["frac_ffn_cpu"])
                 + m.params_attn_other_b * B * b_attn
                 + m.params_output_b * B * b_out)
    # KV 읽기: 평균적으로 현재 컨텍스트의 절반 정도가 채워져 있다고 가정
    gpu_bytes += kv * 0.5
    t = gpu_bytes / (hw.gpu_bw_gbs * 1e9 * hw.gpu_bw_eff) + cpu_bytes / (hw.cpu_bw_gbs * 1e9 * hw.cpu_bw_eff)
    ovh = hw.per_token_overhead_ms / 1000.0 * (2.0 if cpu_bytes > 0 else 1.0)
    tps_ceiling = 1.0 / t if t > 0 else float("inf")
    tps_real = 1.0 / (t + ovh)

    # 프리필(프롬프트 처리) 대략치: CPU 쪽 전문가가 있으면 CPU 연산량에 묶임
    cpu_flops_eff = 8 * 2 * 16 * 2 * 5.0e9 * 0.45  # 8코어 × FMA2 × AVX-512 16lane × 2 × 5GHz × 효율
    gpu_flops_eff = 180e12 * 0.35                  # 5060 Ti FP16/BF16 텐서코어 밀집 대략 ×효율
    flop_per_tok_cpu = 2 * (m.params_experts_active_b * B * parts["frac_moe_cpu"] + m.params_ffn_dense_b * B * parts["frac_ffn_cpu"])
    flop_per_tok_gpu = 2 * (m.params_active_b * B) - flop_per_tok_cpu
    prefill = float("inf")
    if flop_per_tok_cpu > 0:
        prefill = min(prefill, cpu_flops_eff / flop_per_tok_cpu)
    if flop_per_tok_gpu > 0:
        prefill = min(prefill, gpu_flops_eff / flop_per_tok_gpu)

    if not m.verified:
        notes.append("프리셋 수치 미검증(verified=false): 모델 카드로 n_layer/kv heads/파라미터 분해를 확인하세요.")
    if m.params_experts_b and plan.n_cpu_moe == 0 and not fits:
        notes.append("MoE 모델입니다. --n-cpu-moe 로 전문가를 CPU 에 올리면 들어갈 수 있습니다.")
    if moe_cache > 0:
        notes.append(f"--moe-cache-mib {plan.moe_cache_mib}: 적중률 {plan.moe_cache_hit:.0%} 가정. 실제 적중률은 작업 종류에 따라 다릅니다.")
    if m.extra_fixed_gib and "ple" in m.notes.lower():
        notes.append("Gemma PLE(레이어별 임베딩)는 llama.cpp --lazy-mode on 으로 디스크에서 필요 행만 읽어 메모리를 줄일 수 있습니다.")
    if plan.kv_k.lower().startswith("turbo"):
        notes.append("TurboQuant KV 타입은 llama.cpp 메인라인에 없습니다(포크 전용, 실험적). 메인라인에서는 Hadamard 회전 + q4_0/q8_0 KV 를 쓰세요.")
    if hw.os == "windows":
        notes.append("Windows: 모니터가 이 GPU 에 연결되어 있으면 예약 메모리가 더 커질 수 있습니다.")

    return Budget(
        model=m.name, plan=asdict(plan),
        weights_gpu_gib=gpu_w / GiB, weights_cpu_gib=cpu_w / GiB, weights_total_gib=(gpu_w + cpu_w) / GiB,
        file_size_gib=file_w / GiB,
        kv_gib=kv / GiB, kv_bytes_per_token_full=kv_bytes_per_token(m, plan) * m.n_full_layer,
        compute_buf_gib=cbuf / GiB, cuda_ctx_gib=cuda_ctx / GiB, os_reserve_gib=hw.os_reserve_mib * MiB / GiB,
        extra_fixed_gib=extra / GiB, moe_cache_gib=moe_cache / GiB,
        gpu_total_gib=gpu_total / GiB, gpu_budget_gib=budget / GiB, fits=fits, headroom_gib=headroom / GiB,
        max_ctx_fit=max_ctx,
        decode_tps_ceiling=tps_ceiling, decode_tps_realistic=tps_real,
        gpu_bytes_per_token=gpu_bytes, cpu_bytes_per_token=cpu_bytes, prefill_tps_rough=prefill,
        notes=notes,
    )


# ---------------------------------------------------------------------------
# 4. 프리셋 로딩 / 출력
# ---------------------------------------------------------------------------
def load_presets(path: Optional[str] = None) -> dict[str, ModelSpec]:
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)), "presets.json")
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    out = {}
    for k, v in raw["models"].items():
        out[k] = ModelSpec(name=k, **v)
    return out


def fmt_gib(x: float) -> str:
    return f"{x:6.2f} GiB"


def print_budget(b: Budget, m: ModelSpec, hw: Hardware) -> None:
    p = b.plan
    print(f"┌─ {m.name}  ({m.org}, {m.country}; {m.license}; {m.release})")
    if m.notes:
        print(f"│  {m.notes}")
    print(f"│  하드웨어: {hw.gpu_name} ({hw.gpu_vram_gib:.0f} GiB, {hw.gpu_bw_gbs:.0f} GB/s ×{hw.gpu_bw_eff:.2f}) + {hw.cpu_name} (RAM 읽기 {hw.cpu_bw_gbs:.0f} GB/s ×{hw.cpu_bw_eff:.2f}), OS={hw.os}")
    q = p['quant'] + (f" / attn={p['quant_attn']}" if p['quant_attn'] else "") + (f" / out={p['quant_output']}" if p['quant_output'] else "")
    print(f"│  계획: quant={q}, KV={p['kv_k']}/{p['kv_v']}, ctx={p['ctx']:,}, n_cpu_moe={p['n_cpu_moe']}, n_cpu_ffn={p['n_cpu_ffn']}, ubatch={p['ubatch']}")
    print(f"├─ 가중치 파일(전체)      {fmt_gib(b.file_size_gib)}")
    print(f"│  가중치 → GPU           {fmt_gib(b.weights_gpu_gib)}")
    print(f"│  가중치 → CPU(RAM)      {fmt_gib(b.weights_cpu_gib)}   (+ 입력 임베딩은 호스트 메모리)")
    print(f"│  KV 캐시                {fmt_gib(b.kv_gib)}   (풀어텐션 {b.kv_bytes_per_token_full/1024:.1f} KiB/token × {p['ctx']:,})")
    print(f"│  연산 버퍼(추정)        {fmt_gib(b.compute_buf_gib)}")
    print(f"│  CUDA 컨텍스트           {fmt_gib(b.cuda_ctx_gib)}")
    if b.extra_fixed_gib:
        print(f"│  추가 고정(PLE/비전 등)  {fmt_gib(b.extra_fixed_gib)}")
    if b.moe_cache_gib:
        print(f"│  MoE 전문가 GPU 캐시     {fmt_gib(b.moe_cache_gib)}   (--moe-cache-mib)")
    print(f"├─ GPU 합계              {fmt_gib(b.gpu_total_gib)}  /  예산 {fmt_gib(b.gpu_budget_gib)} (VRAM − OS 예약 {b.os_reserve_gib:.2f})")
    verdict = "✅ 들어감" if b.fits else "❌ 초과"
    print(f"│  판정: {verdict}  (여유 {b.headroom_gib:+.2f} GiB)   이 설정의 최대 컨텍스트 ≈ {b.max_ctx_fit:,} 토큰")
    print(f"├─ 디코드 속도 상한(대역폭) ≈ {b.decode_tps_ceiling:6.1f} tok/s   현실적 ≈ {b.decode_tps_realistic:6.1f} tok/s")
    print(f"│  토큰당 GPU 읽기 {b.gpu_bytes_per_token/1e9:.2f} GB, CPU 읽기 {b.cpu_bytes_per_token/1e9:.2f} GB;  프리필 대략 ≈ {b.prefill_tps_rough:,.0f} tok/s")
    for n in b.notes:
        print(f"│  ⚠ {n}")
    print("└" + "─" * 70)


def sweep(presets: dict[str, ModelSpec], hw: Hardware, ctx: int, kv: str) -> None:
    rows = []
    for name, m in presets.items():
        plans = []
        if m.params_experts_b:
            plans.append(("GPU 전부", Plan(quant=m_default_quant(m), kv_k=kv, kv_v=kv, ctx=ctx)))
            plans.append((f"MoE→CPU 전부", Plan(quant=m_default_quant(m), kv_k=kv, kv_v=kv, ctx=ctx, n_cpu_moe=m.n_layer)))
            half = max(1, m.n_layer // 2)
            plans.append((f"MoE→CPU {half}층", Plan(quant=m_default_quant(m), kv_k=kv, kv_v=kv, ctx=ctx, n_cpu_moe=half)))
        else:
            plans.append(("GPU 전부", Plan(quant=m_default_quant(m), kv_k=kv, kv_v=kv, ctx=ctx)))
            if m.params_ffn_dense_b:
                plans.append((f"FFN→CPU {m.n_layer//2}층", Plan(quant=m_default_quant(m), kv_k=kv, kv_v=kv, ctx=ctx, n_cpu_ffn=m.n_layer // 2)))
        for label, p in plans:
            b = estimate(m, hw, p)
            rows.append((name, label, p.quant, b.file_size_gib, b.weights_gpu_gib, b.kv_gib, b.gpu_total_gib,
                         "O" if b.fits else "X", b.max_ctx_fit, b.decode_tps_realistic, m.verified))
    print(f"컨텍스트 {ctx:,}, KV={kv}, GPU 예산 {hw.gpu_vram_gib:.0f} GiB ({hw.os})")
    print(f"{'모델':28} {'배치':14} {'양자화':8} {'파일':>7} {'GPU가중치':>9} {'KV':>6} {'GPU합계':>8} {'적합':>4} {'최대ctx':>9} {'tok/s':>6} {'검증':>4}")
    for r in rows:
        print(f"{r[0]:28} {r[1]:14} {r[2]:8} {r[3]:7.2f} {r[4]:9.2f} {r[5]:6.2f} {r[6]:8.2f} {r[7]:>4} {r[8]:9,} {r[9]:6.1f} {('Y' if r[10] else 'n'):>4}")


def m_default_quant(m: ModelSpec) -> str:
    # MXFP4 네이티브(gpt-oss) 등은 프리셋 notes 에 명시; 기본은 Q4_K_M
    return "mxfp4" if "mxfp4" in m.notes.lower() else "q4_k_m"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--presets", help="presets.json 경로")
    ap.add_argument("--list", action="store_true", help="프리셋 목록")
    ap.add_argument("--model", help="프리셋 이름")
    ap.add_argument("--quant", default="q4_k_m", help="기본 양자화 (예: q4_k_m, iq4_xs, mxfp4, nvfp4, exl3-3.2, 4.0)")
    ap.add_argument("--quant-attn", help="어텐션/기타 텐서 양자화 (예: q6_k, q8_0)")
    ap.add_argument("--quant-embed", help="입력 임베딩 양자화")
    ap.add_argument("--quant-output", help="출력(lm_head) 양자화")
    ap.add_argument("--kv", default="f16", help="KV 캐시 타입 (K,V 동일) 예: f16, q8_0, q4_0, turbo3")
    ap.add_argument("--kv-k", help="K 캐시 타입 (개별 지정)")
    ap.add_argument("--kv-v", help="V 캐시 타입 (개별 지정)")
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--n-cpu-moe", type=int, default=0)
    ap.add_argument("--n-cpu-ffn", type=int, default=0)
    ap.add_argument("--ubatch", type=int, default=512)
    ap.add_argument("--swa-full", action="store_true")
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--moe-cache-mib", type=int, default=0, help="llama.cpp --moe-cache-mib N (CPU 전문가의 GPU 캐시, MiB)")
    ap.add_argument("--moe-cache-hit", type=float, default=0.5, help="전문가 캐시 적중률 가정 (0~1)")
    ap.add_argument("--vram", type=float, default=8.0, help="GPU VRAM GiB")
    ap.add_argument("--gpu-bw", type=float, default=448.0, help="GPU 대역폭 GB/s")
    ap.add_argument("--ram-bw", type=float, default=64.0, help="CPU 가 실제로 읽을 수 있는 RAM 대역폭 상한 GB/s (9700X 단일 CCD = 64 (IF 한계), 9950X 듀얼 CCD ≈ 90, DDR5-6000 이론치 96)")
    ap.add_argument("--os", choices=["linux", "windows"], default="linux")
    ap.add_argument("--sweep", action="store_true", help="모든 프리셋 비교표")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    presets = load_presets(a.presets)
    hw = Hardware(gpu_vram_gib=a.vram, gpu_bw_gbs=a.gpu_bw, cpu_bw_gbs=a.ram_bw, os=a.os,
                  gpu_name=f"GPU {a.vram:.0f} GiB" if a.vram != 8.0 else "RTX 5060 Ti 8GB")

    if a.list:
        for k, m in presets.items():
            moe = f"MoE {m.params_experts_b:.1f}B experts, active {m.params_active_b:.1f}B" if m.params_experts_b else f"dense {m.params_total_b:.1f}B"
            print(f"{k:28} {m.org:12} {m.country:6} {m.license:22} {moe:44} {'검증' if m.verified else '미검증'}")
        return 0
    if a.sweep:
        sweep(presets, hw, a.ctx, a.kv)
        return 0
    if not a.model:
        ap.print_help()
        return 2
    if a.model not in presets:
        raise SystemExit(f"프리셋 없음: {a.model}. --list 로 확인")
    m = presets[a.model]
    plan = Plan(quant=a.quant, quant_attn=a.quant_attn, quant_embed=a.quant_embed, quant_output=a.quant_output,
                kv_k=a.kv_k or a.kv, kv_v=a.kv_v or a.kv, ctx=a.ctx, n_cpu_moe=a.n_cpu_moe, n_cpu_ffn=a.n_cpu_ffn,
                ubatch=a.ubatch, swa_full=a.swa_full, n_parallel=a.parallel,
                moe_cache_mib=a.moe_cache_mib, moe_cache_hit=a.moe_cache_hit)
    b = estimate(m, hw, plan)
    if a.json:
        print(json.dumps(asdict(b), ensure_ascii=False, indent=2))
    else:
        print_budget(b, m, hw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
