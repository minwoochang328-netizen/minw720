#!/usr/bin/env python3
"""vram_budget 단위 테스트 — 공개된 수치로 계산기를 교차검증. 실행: python3 tools/test_vram_budget.py"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vram_budget as vb

P = vb.load_presets()
HW = vb.Hardware()


def approx(a, b, tol):
    return abs(a - b) <= tol * max(1e-9, abs(b))


def test_bpw_table():
    assert vb.bpw_of("mxfp4") == 4.25           # 32×4bit + 8bit E8M0 = 136/32
    assert vb.bpw_of("nvfp4") == 4.5            # 64×4bit + 4×8bit UE4M3 = 288/64
    assert vb.bpw_of("q8_0") == 8.5             # 32×8 + 16 = 272/32
    assert vb.bpw_of("q4_0") == 4.5
    assert approx(vb.bpw_of("exl3-3.0"), 3.03, 0.001)
    assert vb.bpw_of("4.0") == 4.0


def test_llama8b_kv_fp16():
    m = P["llama-3.1-8b"]
    plan = vb.Plan(quant="q4_k_m", kv_k="f16", kv_v="f16", ctx=1)
    per_tok_all_layers = vb.kv_bytes_per_token(m, plan) * m.n_full_layer
    # 2 × 32 layers × 8 heads × 128 dim × 2 bytes = 131072 B = 128 KiB / token (잘 알려진 값)
    assert per_tok_all_layers == 131072, per_tok_all_layers
    plan8k = vb.Plan(quant="q4_k_m", ctx=8192)
    assert approx(vb.kv_total_bytes(m, plan8k), 1 * vb.GiB, 0.001)


def test_llama8b_q4km_file_size():
    m = P["llama-3.1-8b"]
    b = vb.estimate(m, HW, vb.Plan(quant="q4_k_m", ctx=4096))
    # llama-quantize 공식 표: Q4_K_M = 4.58G (Llama-3-8B). 평균 bpw 근사라 ±5% 허용
    assert approx(b.file_size_gib, 4.58, 0.05), b.file_size_gib


def test_gpt_oss_expert_math():
    m = P["gpt-oss-20b"]
    # 전문가: 24층 × 32 × (2880×5760 + 2880×2880) = 19.1B ; 활성: top-4 → 2.39B
    per_expert = 2880 * 5760 + 2880 * 2880
    assert approx(m.params_experts_b * 1e9, 24 * 32 * per_expert, 0.01)
    assert approx(m.params_experts_active_b * 1e9, 24 * 4 * per_expert, 0.01)
    # 전문가 전부 CPU 로 보내면 GPU 상주 가중치는 ~1.2 GiB 이하 (어텐션 0.65B@q8 + lm_head 0.58B@q8)
    b = vb.estimate(m, HW, vb.Plan(quant="mxfp4", quant_attn="q8_0", quant_output="q8_0", kv_k="q8_0", kv_v="q8_0", ctx=32768, n_cpu_moe=24))
    assert b.weights_gpu_gib < 1.4 and b.fits, (b.weights_gpu_gib, b.fits)
    # 전문가 전부 GPU 에 두면 8GB 에 안 들어가야 함
    b2 = vb.estimate(m, HW, vb.Plan(quant="mxfp4", ctx=8192))
    assert not b2.fits


def test_swa_layers_cap_kv():
    m = P["gpt-oss-20b"]
    small = vb.estimate(m, HW, vb.Plan(quant="mxfp4", ctx=4096, n_cpu_moe=24)).kv_gib
    big = vb.estimate(m, HW, vb.Plan(quant="mxfp4", ctx=65536, n_cpu_moe=24)).kv_gib
    # SWA 레이어(12층)는 윈도우 128 로 고정 → 컨텍스트 16배 증가 시 KV 는 16배 미만으로 증가
    assert big < small * 16, (small, big)
    full = vb.estimate(m, HW, vb.Plan(quant="mxfp4", ctx=65536, n_cpu_moe=24, swa_full=True)).kv_gib
    assert full > big


def test_max_ctx_monotonic_and_windows_reserve():
    m = P["llama-3.1-8b"]
    lin = vb.estimate(m, vb.Hardware(os="linux"), vb.Plan(quant="q4_k_m", kv_k="q8_0", kv_v="q8_0", ctx=8192))
    win = vb.estimate(m, vb.Hardware(os="windows"), vb.Plan(quant="q4_k_m", kv_k="q8_0", kv_v="q8_0", ctx=8192))
    assert lin.max_ctx_fit > win.max_ctx_fit > 0
    assert lin.gpu_budget_gib > win.gpu_budget_gib


def test_cli_json(capsys=None):
    import io, json, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = vb.main(["--model", "llama-3.1-8b", "--quant", "iq4_xs", "--kv", "q8_0", "--ctx", "16384", "--json"])
    assert rc == 0
    d = json.loads(buf.getvalue())
    assert d["fits"] is True and d["model"] == "llama-3.1-8b"


def test_moe_cache():
    m = P["gpt-oss-20b"]
    base = vb.estimate(m, HW, vb.Plan(quant="mxfp4", kv_k="q8_0", kv_v="q8_0", ctx=16384, n_cpu_moe=24))
    cached = vb.estimate(m, HW, vb.Plan(quant="mxfp4", kv_k="q8_0", kv_v="q8_0", ctx=16384, n_cpu_moe=24, moe_cache_mib=3072, moe_cache_hit=0.5))
    assert approx(cached.gpu_total_gib - base.gpu_total_gib, 3.0, 0.01)   # 캐시 3 GiB 만큼 GPU 사용 증가
    assert cached.cpu_bytes_per_token < base.cpu_bytes_per_token          # CPU 읽기 감소
    assert cached.decode_tps_realistic > base.decode_tps_realistic        # 속도 상승
    assert cached.fits


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
