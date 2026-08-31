# Agentic kernels in production: lessons for OnePage

Research date: 2026-08-31

Primary source: Baseten, [“Agentic kernels in production”](https://www.baseten.co/blog/agentic-kernels-in-production/), Brian Li, Faraz Shahsavan, and Pankaj Gupta, updated 2026-08-28.

## Bottom line

The article's useful thesis is broader than “agents can write fast CUDA kernels.” A candidate optimization matters only if it survives correctness checks, integration into the real serving engine, and an end-to-end measurement on the production-shaped workload. Baseten therefore uses two search layers:

1. profile the complete model and change its execution graph by fusing work, eliminating repeated work, or avoiding intermediate materialization;
2. optimize only the important generated or existing kernels, explore several implementations, and retain the strongest candidate.

Both routes pass through microbenchmarks, correctness checks, ablations, engine integration, and end-to-end performance checks. Successful patches, tests, benchmarks, and workload facts are retained; failed attempts are recorded with caveats and root causes. The article argues that a locally faster kernel can still lose after CUDA graph capture, multi-stream execution, launch overhead, and serving-engine integration.

Bryce Lelbach's screenshot commentary is a fair reading of one part of this: launch and transfer latency, plus insufficient exposed parallelism, disappear when kernels are studied in isolation. The article itself makes the wider claim that the optimization unit is the complete deployed workload, including its execution graph and serving runtime.

## What Baseten measured

The disclosed experiment used Qwen-Image and FLUX.2 served with SGLang on NVIDIA B300 GPUs, in FP8 and NVFP4 configurations. The published metric is median denoising latency in milliseconds per step; lower is better. The exact values come from Baseten's [result chart](https://www.datocms-assets.com/104802/1787958561-graph_1_update-1.png?auto=format&w=2400).

| Workload | Baseline | After model-level work | After kernel-level work | Model-level reduction | Additional kernel reduction | Total reduction |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FLUX.2 FP8 | 137.1 ms | 118.6 ms | 116.2 ms | 13.5% | 2.0% | 15.2% |
| FLUX.2 NVFP4 | 84.6 ms | 74.8 ms | 72.1 ms | 11.6% | 3.6% | 14.8% |
| Qwen-Image FP8 | 245.6 ms | 154.9 ms | 141.8 ms | 36.9% | 8.5% | 42.3% |
| Qwen-Image NVFP4 | 161.2 ms | 145.3 ms | 132.5 ms | 9.9% | 8.8% | 17.8% |

“Model-level reduction” and “total reduction” use the baseline as denominator; “additional kernel reduction” uses the model-level result. The headline 42.3% and 15.2% claims correspond to Qwen-Image FP8 and FLUX.2 FP8.

The model-level changes included pre-packing FP8 scales, moving constant scale packing to model load, merging Q/K/V projections, fusing normalization with quantization, absorbing bias into later operations, and caching prompt-independent classifier-free-guidance modulation. The kernel pass then tuned the performance-critical and newly fused kernels. FLUX.2-specific work fused QK normalization with RoPE, SwiGLU with quantization, and gated residual update with normalization. Baseten also publishes cumulative-ablation charts for [Qwen-Image](https://www.datocms-assets.com/104802/1787955583-graph_3-1.png?auto=format&w=2400) and [FLUX.2](https://www.datocms-assets.com/104802/1787956154-graph_2-2.png?auto=format&w=2400). The post reports an early 5.5% tokens-per-second gain on MiniMax M3 and GLM-5.2 on vLLM, but gives no accompanying result table or methodology.

### Reproducibility limit

This is production evidence, not a reproducible benchmark publication. The headline says “end-to-end latency,” but the plotted quantity is median denoiser-step time; the post does not define whether request setup, prompt transfer, scheduling, or post-processing is inside that boundary. It also does **not** disclose prompt/image resolution, batch size, GPU count, model revisions, SGLang revision, CUDA/Triton/driver versions, warm-up policy, number of samples, run-to-run variance, concurrency, or clocks/power policy. It publishes no raw data, patches, agent framework, or benchmark harness. Its only substantive external code link is the unrelated background benchmark [KernelBench](https://github.com/ScalingIntelligence/KernelBench), whose own evaluation checks generated kernels for correctness against randomized PyTorch inputs and times them against the reference implementation. Baseten's production results should therefore be treated as credible first-party case-study claims, not independently verified effect sizes.

## Transferable to OnePage

### Measure the Run, then the phases, then the primitive

OnePage should make its top-line optimization target a production-shaped durable Run or Job Attempt, not a parser, HTTP callback, SQLite statement, or allocator microbenchmark. A useful measurement stack is:

1. end-to-end Job and Run latency, throughput, peak physical footprint, durable bytes, and recovery behavior;
2. phase measurements and ablations for admission wait, request reconstruction, DNS/connect/TLS, time to first model event, streaming/capture, durable publication, tool execution, evaluator activation, and resume;
3. microbenchmarks only for a phase proven material by the traces.

This complements OnePage's existing capacity matrix and resource accounting. Median alone is insufficient for a local agent runtime: record at least p50, p95, peak, and failure/cancellation behavior under the same provider, model, response size, tool pattern, network condition, and `active_capacity`.

### Keep the common lifecycle deep; keep wire protocols at the edge

The article supports optimizing across module boundaries, but it does not support pretending provider protocols are identical. In OnePage, these concerns should remain common:

- Active Credit admission, Attempt ownership, deadlines and cancellation settlement;
- the provider-neutral Conversation and immutable request cursor;
- bounded candidate capture and durable Completion publication;
- normalized failure meaning, metrics, tracing, and the benchmark/ablation harness;
- executor, shutdown, crash recovery, and resource accounting.

These concerns remain provider-specific:

- authentication and refresh, endpoint and headers;
- request JSON and tool lowering;
- SSE/WebSocket/HTTP response grammar and terminal-event rules;
- upstream diagnostic extraction and status mapping;
- provider replay IDs, model quirks, and compatibility policy.

That is already the intended shape of `model_operation.Provider.dispatch(RequestCursor, CandidateWriter)`: the Harness and durable lifecycle need not know Codex. `codex_provider.zig` and `codex_native.zig` are appropriately Codex-heavy because they lower the house request and implement the observed Codex HTTP/SSE protocol. A later provider may justify extracting a shared bounded HTTP transfer substrate, but only after the second implementation demonstrates a stable common contract. Do not generalize Codex's SSE terminal rules, diagnostics, OAuth, or endpoint behavior into the provider-neutral seam.

### Retain evidence, not autonomous production mutation

Baseten's success/dead-end memory is transferable as a benchmark corpus: keep the exact workload identity, patch, correctness result, phase trace, end-to-end result, and rejection reason. For OnePage V1 this should be checked-in fixtures, raw benchmark artifacts, and short research/decision notes. A self-modifying optimizer or production patch database would add an authority and lifecycle that the bounded local runtime does not need.

## CUDA-specific and not directly transferable

Tile shapes, warps, CTAs, CUDA graph capture, GPU streams, tensor precision formats, GEMM packing, RoPE, SwiGLU, and kernel fusion are specific to accelerator inference. OnePage does not own the provider's model-serving kernels, so these techniques are neither an implementation roadmap nor evidence that OnePage should embed a second optimization agent.

The transferable pattern is narrower: optimize the actual bottleneck in its complete workload, require correctness and end-to-end gates, and preserve workload-specific evidence. For OnePage, the likely bottlenecks are network/provider wait, bounded transport and capture memory, executor topology, durable I/O, tool subprocesses, and repeated request reconstruction—not CUDA kernels.

## Recommended next move

Use the existing capacity-one and planned 1/10/50/100 transport runs as the first end-to-end trace corpus. Add phase timestamps and high-water measurements without changing authority boundaries. Only after those traces identify a material repeated cost should OnePage optimize or extract networking machinery. This follows the article's strongest lesson while keeping the provider-neutral Harness deeper than any one Codex transport.
