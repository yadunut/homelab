# Inkling 2 Mini benchmark — 2026-11-28

For raw single-request token throughput on Penguin, the fastest tested choice was
**Unsloth `UD-Q2_K_XL` with DSpark speculation, depth 2**: 45.6 tokens/sec on
the prose prompt and 37.0 tokens/sec on the code prompt. Qwen was restored after
the experiment. A subsequent production cutover selects Q2 with DSpark depth 2;
see [the current deployment configuration](llama.md).

## Hardware and method

- Penguin: NVIDIA RTX 2000 Ada Generation, 16,380 MiB VRAM, driver 595.112.07;
  AMD Ryzen 9 9955HX and approximately 60 GiB system RAM.
- The observed **49 W GPU power limit was unchanged** throughout. This differs
  from the 70 W configuration used in the older September Qwen benchmarks.
- One request at a time, text only, greedy sampling, fixed prompts and seed,
  no prompt-cache reuse. The prompts ask for an operational review and an
  asyncio queue implementation, with the same synthetic service inventory.
- Main Qwen/GGUF results are medians of three requests per prompt, each forced
  to generate 512 tokens, following an excluded warm-up. Context capacity was
  65,536 tokens; actual input lengths were 1,744/1,753 tokens for Inkling and
  1,847/1,852 for Qwen. This is not a benchmark at 64K occupied context.
- llama.cpp decode and prefill rates use its server-reported timings. Latencies
  in the tables below use a client running on Penguin, excluding model loading.
  The initial Qwen baseline used a remote client, so its client latency is not
  included in the latency comparison.
- The original checkpoint was measured separately with Transformers: one
  32-token sample per prompt because generation was extremely slow. Matching
  32-token samples were also collected for each GGUF configuration and Qwen.
- Qwen thinking was disabled. Inkling used `reasoning_effort=none`, but **all
  512-token Inkling samples remained in reasoning and did not reach a final
  answer**. These are token-generation measurements, not task-completion or
  quality scores. Different tokenizers also limit cross-model comparisons.

## Generation throughput

| Configuration | Prose prompt, tok/s | Code prompt, tok/s | Peak VRAM, GiB |
|---|---:|---:|---:|
| Original checkpoint, Transformers BF16 + CPU offload, 32 tokens | 0.135 | 0.135 | 12.6 |
| Unsloth UD-Q2_K_XL, no speculation | 36.5 | 36.0 | 11.2 |
| **Unsloth UD-Q2_K_XL, DSpark depth 2** | **45.6** | **37.0** | **12.0** |
| Unsloth UD-IQ3_XXS, no speculation | 31.6 | 31.5 | 13.5 |
| Unsloth UD-IQ3_XXS, DSpark depth 2 | 34.9 | 33.5 | 14.3 |
| Existing Qwen IQ3_XXS + MTP depth 3, before experiment | 20.4 | 20.5 | 14.8 |
| Existing Qwen IQ3_XXS + MTP depth 3, after restoration | 17.9 | 18.4 | 14.8 |

DSpark improved Q2's prose decode rate by about 25%, but its code-prompt gain
was only about 3%. Q2 with DSpark was about 31% faster than IQ3 with DSpark on
prose and 10% faster on the code prompt, while using about 2.3 GiB less VRAM.
Relative to the faster, initial Qwen baseline, it delivered about 2.2x and 1.8x
the generation throughput respectively.

The before/after Qwen variation is retained rather than choosing a favorable
baseline. The restored Deployment spec matched the saved original exactly, and
all six paired greedy outputs were identical. This was a live-system experiment,
not a controlled thermal laboratory comparison. Temperatures reached 89 C;
793 samples collected from the Q2 speculative stage through final verification
showed no software or hardware thermal-slowdown flags. The 49 W power cap was
active during generation.

## Prefill and latency

Prose / code values; 512 generated tokens, except the native row.

| Configuration | Prefill, tok/s | First streamed token, seconds | Whole request, seconds |
|---|---:|---:|---:|
| Original Transformers, 32 generated tokens | Not measured separately | 10.85 / 11.06 | 240.49 / 240.63 |
| Q2, no speculation | 536 / 513 | 3.32 / 3.48 | 17.24 / 17.60 |
| Q2, DSpark depth 2 | 493 / 487 | 3.60 / 3.67 | 14.74 / 17.40 |
| IQ3, no speculation | 458 / 455 | 3.88 / 3.95 | 19.96 / 20.08 |
| IQ3, DSpark depth 2 | 452 / 451 | 3.93 / 4.00 | 18.49 / 19.16 |
| Qwen, after restoration | 324 / 316 | 5.70 / 5.90 | 34.19 / 33.76 |

Time to the first streamed token includes reasoning where present, not time to
the first final-answer token. Speculation adds some prefill cost, so the decode
improvement is larger than the whole-request improvement. With only 32 generated
tokens, Q2 took approximately 4.3–4.4 seconds with or without speculation,
whereas the original checkpoint took approximately 240 seconds.

## Original checkpoint execution

The original Thinking Machines checkpoint was attempted before the Unsloth runs.
The model safetensors SHA-256 was verified against Hugging Face's metadata.

1. Native vLLM `0.34.1rc1.dev319+g70b67cf80` recognized the architecture, but ran
   out of GPU memory constructing expert weights despite `--cpu-offload-gb 12`.
   It failed before serving requests; there is no vLLM throughput result.
2. Transformers `5.24.1`, Torch `2.14.0+cu130`, successfully loaded the original
   weights. Its Inkling conversion path expands NVFP4/MXFP8 experts into BF16.
   The final run used `device_map=auto`, 12 GiB GPU / 42 GiB CPU placement budgets,
   a 48 GiB container limit, and 16 CPU threads. No layers were assigned to disk.
   Loading reported zero missing, unexpected, or mismatched weights.
3. This path used the reference PyTorch causal-convolution implementation;
   `causal_conv1d` was unavailable. The approximately 0.135 tok/s result describes
   this CPU-offloaded fallback on this machine, **not the intrinsic performance
   of the original model on hardware that can keep it resident**.

An earlier disk-offloaded smoke attempt and a reload that exhausted VRAM were
excluded from the reported samples. Temporary disk-offload files were removed.

## Reproducible versions and settings

- Original model: [thinkingmachines/Inkling-2-Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini/tree/c9d028302cd0f035fdf8e7e91f089a4ce94d2195),
  revision `c9d028302cd0f035fdf8e7e91f089a4ce94d2195`.
- GGUFs: [unsloth/Inkling-2-Mini-GGUF](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/tree/8078d149286eec7193795413b9e0643da6d11fa1),
  revision `8078d149286eec7193795413b9e0643da6d11fa1`. Q2, IQ3, and the drafter
  all passed SHA-256 checks.
- Runtime: Unsloth llama.cpp `b12649-mix-c7059d6`, source commit
  `189f431bf58f433d376d718c7788b1bf4467fa72`, CUDA 12 portable build. A temporary
  container used NVIDIA CUDA 12.8.1 runtime libraries.
- Common GGUF flags: `--ctx-size 65536 --parallel 1 --n-gpu-layers 99
  --flash-attn on --cache-type-k f16 --cache-type-v f16 --batch-size 512
  --ubatch-size 512 --threads 16 --threads-batch 16 --reasoning-effort none`.
- Speculative runs added `--model-draft dspark-Inkling-2-Mini-Q8_0_Old.gguf
  --spec-type draft-dspark --spec-draft-n-max 2 --n-gpu-layers-draft 99`.
- The vLLM container digest was
  `sha256:9506521f790c4cd2dc652b373126dd959feeb9810cf865b76966eb96582a5d82`.
  The CUDA runtime base digest was
  `sha256:fcbbd60a5ad3db3a1c7375bf14546b369b54064c513224310b2026df50c7a9bd`.

Raw JSONL responses, GPU samples, commands, logs, version metadata, benchmark
scripts, and `summary.json` are in `/srv/inkling-benchmark-20261128` on Penguin,
with a local evidence mirror at
`/Users/yadunut/.bb/thread-storage/inkling-benchmark-20261128`.
Original model downloads, GGUFs, and runtime images remain cached for reuse.

## Restoration at the end of the benchmark

Qwen was Running and Ready with its original model, arguments, replica count, and
GPU allocation. Flux's `llama` Kustomization was Ready at
`d02ccd4eadd77d2b8b779c77a85e69a29c222b10`. Temporary reconciliation exclusions
were removed, reconciliation resumed, benchmark containers stopped/removed, and
both automatic restoration timers were canceled. No model deployment was
committed or pushed during the experiment. The later requested production switch
is separate from this restoration check.
