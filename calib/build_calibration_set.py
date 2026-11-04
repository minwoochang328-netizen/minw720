#!/usr/bin/env python3
"""
build_calibration_set.py — imatrix / EXL3 / NVFP4(ModelOpt) 캘리브레이션용 한국어+영어+코드 혼합 텍스트 생성

왜 섞는가:
  imatrix 는 "캘리브레이션 텍스트에서 활성화된 가중치"를 중요하게 보존합니다. 영어 위키만 쓰면
  한국어 토큰 경로(임베딩·어텐션·전문가)가 덜 보호되어 한국어 품질이 먼저 깨집니다.
  기본 배합: 한국어 40% / 영어 35% / 코드 15% / 대화형(지시-응답) 10%.

데이터 소스(모두 Hugging Face `datasets` 스트리밍, 재배포하지 않고 로컬 캘리브레이션에만 사용):
  ko   : wikimedia/wikipedia (20231101.ko)             CC-BY-SA 4.0
  en   : Salesforce/wikitext (wikitext-103-raw-v1, train) CC-BY-SA 3.0
  code : codeparrot/github-code-clean (MIT/Apache/BSD 라이선스 파일만 필터)
  chat : HuggingFaceH4/ultrachat_200k (MIT) + maywell/ko_wikidata_QA (CC-BY-SA 4.0)
  --extra 로 자신의 도메인 텍스트(판매 제품의 실제 사용 문서 등)를 추가하면 가장 좋습니다.

사용법:
  pip install datasets
  python calib/build_calibration_set.py --target-chars 6000000 --out calib/calibration_ko_en_code.txt
  python calib/build_calibration_set.py --dry-run           # 네트워크 없이 로직만 점검
  python calib/build_calibration_set.py --holdout calib/eval_holdout.txt   # 평가용(KLD) 별도 세트도 생성

출력: 약 2~3K 토큰 단위의 조각을 소스별로 라운드로빈 섞어 하나의 텍스트 파일로 저장.
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import os
import random
import re
import sys
from typing import Iterable, Iterator

DEFAULT_MIX = {"ko": 0.40, "en": 0.35, "code": 0.15, "chat": 0.10}
CHUNK_CHARS = 6000          # 한 조각 ≈ 1.5~3K 토큰 (한국어는 토큰당 글자수가 적어 조각당 토큰이 더 많음)
MIN_CHUNK_CHARS = 1500
ALLOWED_CODE_LICENSES = {"mit", "apache-2.0", "bsd-3-clause", "bsd-2-clause", "isc", "unlicense", "cc0-1.0"}


def clean(text: str) -> str:
    text = text.replace("\r\n", "\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def chunker(docs: Iterable[str], chunk_chars: int = CHUNK_CHARS) -> Iterator[str]:
    """문서 스트림을 chunk_chars 근처의 조각으로 자른다(문단 경계 우선)."""
    buf: list[str] = []
    size = 0
    for d in docs:
        d = clean(d)
        if len(d) < 200:
            continue
        for para in d.split("\n\n"):
            buf.append(para)
            size += len(para) + 2
            if size >= chunk_chars:
                yield "\n\n".join(buf)
                buf, size = [], 0
    if size >= MIN_CHUNK_CHARS:
        yield "\n\n".join(buf)


def interleave(streams: dict[str, Iterator[str]], mix: dict[str, float], target_chars: int, seed: int = 0) -> Iterator[tuple[str, str]]:
    """가중 라운드로빈으로 소스를 섞어 target_chars 까지 조각을 내보낸다."""
    rng = random.Random(seed)
    names = list(streams)
    weights = [mix[n] for n in names]
    emitted = 0
    exhausted: set[str] = set()
    while emitted < target_chars and len(exhausted) < len(names):
        live = [(n, w) for n, w in zip(names, weights) if n not in exhausted]
        n = rng.choices([x[0] for x in live], weights=[x[1] for x in live])[0]
        try:
            chunk = next(streams[n])
        except StopIteration:
            exhausted.add(n)
            continue
        emitted += len(chunk)
        yield n, chunk


# ----------------------------------------------------------------------------- 소스 (지연 import)
def src_ko_wiki(seed: int) -> Iterator[str]:
    from datasets import load_dataset
    ds = load_dataset("wikimedia/wikipedia", "20231101.ko", split="train", streaming=True).shuffle(seed=seed, buffer_size=2000)
    for row in ds:
        yield row["text"]


def src_en_wikitext(seed: int) -> Iterator[str]:
    from datasets import load_dataset
    ds = load_dataset("Salesforce/wikitext", "wikitext-103-raw-v1", split="train", streaming=True)
    # wikitext 는 줄 단위 → 문서 단위로 재조립
    doc: list[str] = []
    for row in ds:
        line = row["text"]
        if line.startswith(" = ") and not line.startswith(" = = ") and doc:
            yield "".join(doc)
            doc = []
        doc.append(line)
    if doc:
        yield "".join(doc)


def src_code(seed: int) -> Iterator[str]:
    from datasets import load_dataset
    ds = load_dataset("codeparrot/github-code-clean", split="train", streaming=True).shuffle(seed=seed, buffer_size=2000)
    langs = {"Python", "JavaScript", "TypeScript", "C", "C++", "Go", "Rust", "Java", "Shell", "SQL"}
    for row in ds:
        if row.get("license", "").lower() in ALLOWED_CODE_LICENSES and row.get("language") in langs:
            code = row["code"]
            if 300 <= len(code) <= 20000:
                yield f"// file: {row.get('path','')} ({row.get('language')})\n{code}"


def src_chat(seed: int) -> Iterator[str]:
    from datasets import load_dataset
    en = load_dataset("HuggingFaceH4/ultrachat_200k", split="train_sft", streaming=True).shuffle(seed=seed, buffer_size=1000)
    ko = load_dataset("maywell/ko_wikidata_QA", split="train", streaming=True).shuffle(seed=seed, buffer_size=1000)
    en_it, ko_it = iter(en), iter(ko)
    while True:
        for _ in range(2):  # 한국어 QA 2 : 영어 대화 1
            row = next(ko_it, None)
            if row is None:
                return
            yield f"### 질문\n{row['instruction']}\n\n### 답변\n{row['output']}\n"
        row = next(en_it, None)
        if row is None:
            return
        turns = row["messages"]
        yield "\n".join(f"### {m['role'].capitalize()}\n{m['content']}\n" for m in turns)


SOURCES = {"ko": src_ko_wiki, "en": src_en_wikitext, "code": src_code, "chat": src_chat}


def synthetic_streams(seed: int) -> dict[str, Iterator[str]]:
    """--dry-run 용 가짜 데이터(네트워크 없음)."""
    rng = random.Random(seed)
    def gen(prefix: str, n: int):
        for i in range(n):
            yield "\n\n".join(f"{prefix} 문단 {i}-{j} " + " ".join(str(rng.random())[:6] for _ in range(80)) for j in range(12))
    return {"ko": gen("한국어", 60), "en": gen("English", 60), "code": gen("code", 30), "chat": gen("chat", 20)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "calibration_ko_en_code.txt"))
    ap.add_argument("--holdout", help="평가(KLD/PPL)용 별도 파일 경로. 캘리브레이션과 겹치지 않게 다른 시드로 생성")
    ap.add_argument("--target-chars", type=int, default=6_000_000, help="목표 글자수 (6M 글자 ≈ 2~3M 토큰)")
    ap.add_argument("--holdout-chars", type=int, default=600_000)
    ap.add_argument("--mix", default=",".join(f"{k}={v}" for k, v in DEFAULT_MIX.items()), help="예: ko=0.5,en=0.3,code=0.1,chat=0.1")
    ap.add_argument("--extra", action="append", default=[], help="추가 텍스트 파일(도메인 데이터). 여러 번 지정 가능. 'extra' 소스로 15% 비중 추가")
    ap.add_argument("--seed", type=int, default=20261104)
    ap.add_argument("--dry-run", action="store_true", help="네트워크 없이 합성 데이터로 파이프라인 점검")
    a = ap.parse_args(argv)

    mix = {k: float(v) for k, v in (kv.split("=") for kv in a.mix.split(","))}
    if a.extra:
        mix = {k: v * 0.85 for k, v in mix.items()}
        mix["extra"] = 0.15

    def build(seed: int, target: int, out_path: str):
        if a.dry_run:
            raw = synthetic_streams(seed)
        else:
            raw = {name: SOURCES[name](seed) for name in mix if name in SOURCES}
        if a.extra:
            def extra_docs():
                for p in a.extra:
                    with open(p, encoding="utf-8", errors="ignore") as f:
                        yield f.read()
            raw["extra"] = extra_docs()
        streams = {k: chunker(v) for k, v in raw.items()}
        counts = {k: 0 for k in streams}
        chars = {k: 0 for k in streams}
        seen: set[str] = set()
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            for name, chunk in interleave(streams, {k: mix.get(k, 0.0) for k in streams}, target, seed):
                h = hashlib.sha1(chunk[:2000].encode("utf-8")).hexdigest()
                if h in seen:
                    continue
                seen.add(h)
                f.write(chunk + "\n\n")
                counts[name] += 1
                chars[name] += len(chunk)
        total = sum(chars.values()) or 1
        print(f"[OK] {out_path}: {total:,} chars")
        for k in streams:
            print(f"     {k:6} {counts[k]:5} chunks {chars[k]:>10,} chars ({chars[k]/total:5.1%})")

    build(a.seed, a.target_chars, a.out)
    if a.holdout:
        build(a.seed + 1, a.holdout_chars, a.holdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
