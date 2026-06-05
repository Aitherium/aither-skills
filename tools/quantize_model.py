#!/usr/bin/env python3
"""quantize_model.py — Shrink an LLM to 4-bit with AutoRound, locally and free.

Round-to-nearest (RTN) 4-bit quantization that fits a model where bf16 won't,
runs on your own CPU + GPU (host-RAM offload for what won't fit VRAM), and bakes
in the hard-won gotchas that otherwise produce a broken or un-loadable artifact.

Why RTN by default
------------------
RTN (``--iters 0``) is **weight-only**: round each weight to the nearest 4-bit
grid, no calibration data, no forward pass. Peak VRAM is tiny (~<2 GB) and it
finishes in ~1 minute, so it runs on a laptop GPU + CPU. ``$0``, fully local.

Calibrated AWQ (``--iters > 0``) runs a forward pass per layer to learn better
rounding — higher quality, but it needs a real GPU and calibration data, and it
**crashes on some newer architectures** (see ``--iters`` note below). For most
models RTN is enough to make them fit and stay coherent.

The gotchas this handles for you
--------------------------------
1. **AutoRound, not llm-compressor.** llm-compressor pins an old ``transformers``
   and silently downgrades it until a new-architecture model won't load. This
   tool uses AutoRound, which tracks current transformers.
2. **Quantize only the language decoder.** Multimodal vision/audio projectors
   and ``lm_head`` must stay bf16 — vLLM's loaders expect them unquantized.
   ``--keep-fp`` patterns (default already covers the common cases) are forced
   to 16-bit in the layer config.
3. **Export ``compressed-tensors``** (``--format llm_compressor``, the default)
   when modules are kept un-quantized, so they ship as plain ``.weight`` tensors
   instead of being wrapped by ``auto_awq``'s packing.
4. **Heterogeneous head dims.** Some new models (e.g. alternating
   sliding/global attention with 256/512 head dims) crash AutoRound's
   *calibrated* path. This tool detects that and refuses ``--iters > 0`` with a
   clear message, steering you to RTN.

Examples
--------
    # The common case: RTN 4-bit, local + free, sensible defaults
    python quantize_model.py google/gemma-3-12b-it -o ./gemma-3-12b-it-awq

    # Preview the whole plan without loading weights or writing anything
    python quantize_model.py meta-llama/Llama-3.1-8B-Instruct --dry-run

    # Calibrated AWQ on a GPU (needs calibration; refused on het-head models)
    python quantize_model.py mistralai/Mistral-7B-Instruct-v0.3 \
        -o ./mistral-7b-awq --iters 200 --nsamples 128

    # Keep extra modules in bf16 (regex, repeatable)
    python quantize_model.py some/vlm -o ./vlm-awq \
        --keep-fp 'vision_tower' --keep-fp 'multi_modal_projector'

Serve the result in vLLM with:  --quantization awq_marlin   (or compressed-tensors)

Exit codes: 0 = success, 1 = quantization/runtime error, 2 = bad input / missing deps.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Default regexes for modules that must NOT be quantized. Covers lm_head and the
# usual multimodal projector / encoder names across Llama/Gemma/Qwen/Llava VLMs.
DEFAULT_KEEP_FP = [
    r"lm_head",
    r"embed_tokens",
    r"vision_tower",
    r"vision_model",
    r"visual\b",
    r"multi_modal_projector",
    r"mm_projector",
    r"audio_tower",
    r"audio_model",
]


def _die(msg: str, code: int = 2) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _detect_heterogeneous_heads(config) -> str | None:
    """Return a human description if the model uses per-layer-type head dims.

    Newer architectures (alternating sliding/global attention) carry a rotary /
    head-dim that differs by layer type. AutoRound's calibrated path replays one
    block's rotary into every block and crashes (cos/sin shape mismatch). RTN is
    unaffected. Returns a descriptive string when detected, else None.
    """
    suspects = {}
    for attr in ("head_dim", "sliding_window_pattern", "rope_local_base_freq",
                 "layer_types", "sliding_window"):
        val = getattr(config, attr, None)
        if val is not None:
            suspects[attr] = val
    # Strong signal: a layer_types list with more than one distinct type, or an
    # explicit per-type head dim dict.
    lt = getattr(config, "layer_types", None)
    if isinstance(lt, (list, tuple)) and len(set(lt)) > 1:
        return f"layer_types has mixed entries ({sorted(set(lt))})"
    for attr in ("head_dim", "rope_scaling"):
        val = getattr(config, attr, None)
        if isinstance(val, dict) and len(val) > 1:
            return f"{attr} is per-layer-type ({val})"
    return None


def _build_layer_config(model, keep_fp_patterns: list[str]) -> tuple[dict, list[str]]:
    """Map every Linear matching a keep-fp pattern to 16-bit (left un-quantized)."""
    try:
        import torch.nn as nn
    except ImportError:  # pragma: no cover - torch absence handled in main
        _die("torch is required. Install: pip install torch", 2)
    compiled = [re.compile(p) for p in keep_fp_patterns]
    layer_config: dict[str, dict] = {}
    kept: list[str] = []
    for name, module in model.named_modules():
        if isinstance(module, nn.Linear) and any(rx.search(name) for rx in compiled):
            layer_config[name] = {"bits": 16}
            kept.append(name)
    return layer_config, kept


def main() -> int:
    p = argparse.ArgumentParser(
        description="Quantize an LLM to 4-bit with AutoRound (RTN by default).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("model", help="HF repo id or local path of the source model")
    p.add_argument("-o", "--output", help="Output dir for the quantized model")
    p.add_argument("--bits", type=int, default=4, help="Quant bits (default 4)")
    p.add_argument("--group-size", type=int, default=128,
                   help="Quant group size (default 128)")
    p.add_argument("--iters", type=int, default=0,
                   help="0 = RTN (free, weight-only, default). >0 = calibrated AWQ "
                        "(needs a GPU + calibration; refused on het-head models).")
    p.add_argument("--nsamples", type=int, default=128,
                   help="Calibration samples when --iters > 0 (default 128)")
    p.add_argument("--format", default="llm_compressor",
                   choices=["llm_compressor", "auto_round", "auto_awq", "auto_gptq"],
                   help="Export format (default llm_compressor / compressed-tensors, "
                        "the safe choice when modules are kept un-quantized)")
    p.add_argument("--keep-fp", action="append", default=[], metavar="REGEX",
                   help="Extra module-name regex to keep in bf16 (repeatable). "
                        "Added on top of the built-in lm_head/projector defaults.")
    p.add_argument("--device", default="auto",
                   help="device_map for loading (default 'auto' = CPU+GPU offload)")
    p.add_argument("--no-default-keep-fp", action="store_true",
                   help="Don't apply the built-in keep-fp defaults (advanced)")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the plan and exit — no weight load, no write, no GPU")
    args = p.parse_args()

    keep_fp = list(args.keep_fp)
    if not args.no_default_keep_fp:
        keep_fp = DEFAULT_KEEP_FP + keep_fp

    mode = "RTN (weight-only, free, local)" if args.iters == 0 \
        else f"calibrated AWQ (iters={args.iters}, nsamples={args.nsamples})"

    print("=== Quantization plan ========================================")
    print(f"  source model : {args.model}")
    print(f"  output dir   : {args.output or '(required unless --dry-run)'}")
    print(f"  scheme       : {args.bits}-bit, group_size={args.group_size}")
    print(f"  mode         : {mode}")
    print(f"  export format: {args.format}")
    print(f"  device_map   : {args.device}")
    print(f"  keep in bf16 : {', '.join(keep_fp) or '(none)'}")
    print("==============================================================")

    if not args.dry_run and not args.output:
        _die("-o/--output is required (or use --dry-run to preview).", 2)

    if args.dry_run:
        print("dry-run: not loading weights. Re-run without --dry-run to execute.")
        return 0

    # Imports are deferred so --dry-run and --help work without the heavy stack.
    try:
        import torch
        from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer
    except ImportError as e:
        _die(f"missing dependency ({e}). Install: pip install torch transformers", 2)
    try:
        from auto_round import AutoRound
    except ImportError:
        _die("auto-round not installed. Install: pip install auto-round", 2)

    # Het-head guard — only the calibrated path is affected; RTN is safe.
    try:
        cfg = AutoConfig.from_pretrained(args.model, trust_remote_code=True)
        het = _detect_heterogeneous_heads(cfg)
    except Exception as e:  # config load is best-effort; don't block RTN on it
        print(f"  (config probe skipped: {e})")
        het = None
    if het and args.iters > 0:
        _die(
            "this model uses per-layer-type head dims "
            f"({het}); AutoRound's calibrated path (--iters > 0) crashes on it. "
            "Use RTN (--iters 0) — it produces a valid 4-bit artifact here.",
            2,
        )
    if het:
        print(f"  note: heterogeneous heads detected ({het}); RTN is the safe path.")

    print(f"\nLoading {args.model} (bf16, device_map={args.device}) ...")
    model = AutoModelForCausalLM.from_pretrained(
        args.model, torch_dtype=torch.bfloat16,
        device_map=args.device, trust_remote_code=True,
    )
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)

    layer_config, kept = _build_layer_config(model, keep_fp)
    print(f"Keeping {len(kept)} module(s) in bf16 (lm_head / projectors / encoders).")

    print(f"\nQuantizing -> {args.bits}-bit ({mode}) ...")
    ar = AutoRound(
        model,
        tokenizer,
        bits=args.bits,
        group_size=args.group_size,
        sym=True,
        iters=args.iters,
        nsamples=args.nsamples,
        layer_config=layer_config or None,
    )
    try:
        ar.quantize_and_save(output_dir=args.output, format=args.format)
    except TypeError:
        # Older AutoRound: quantize() then save_quantized()
        ar.quantize()
        ar.save_quantized(args.output, format=args.format)

    print(f"\nDone. Quantized model written to: {args.output}")
    print("  Serve with vLLM:  vllm serve "
          f"{args.output} --quantization awq_marlin")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        raise SystemExit(130)
