# #2047 How much RAM each harness takes from an on-device model

Researched 2026-11-23. Labels: **[source]** quoted from a primary source; **[arithmetic]** computed from sourced figures; **[estimate]** not measured, not sourced.

## Answer

The model owns almost all the memory. A Q4 8B model takes about 5.5 GB with one 4K-token context, and every agent *generating at the same time* needs its own KV-cache slot of about 0.5 to 0.6 GB. Measured harnesses add 2 MB (Rui) to 0.65 GB (OpenCode) at 100 waiting agents. Rui's saving is real but small next to the model: about 0.1 to 0.2 GB against pi and Codex app-server, which is less than one extra KV slot and nowhere near the ~4 GB step from an 8B to a 14B model. Only against OpenCode (~0.55 to 0.65 GB) or one-CLI-process-per-agent SDKs at 10+ agents (estimated, unverified) is the gap big enough to change what fits on an 8 or 16 GB machine.

## Model RAM

### Weights (local runners)

Ollama default tags, download size **[source]** (ollama.com/library/*/tags, fetched 2026-11-23). Default quant matched by digest to `q4_K_M` where stated.

| Model | Ollama tag | Size | Context window (model max) |
| --- | --- | ---: | ---: |
| Qwen3 4B | qwen3:4b | 2.5 GB | 256K |
| Qwen3 8B | qwen3:8b (q4_K_M) | 5.2 GB | 40K |
| Qwen3 14B | qwen3:14b (q4_K_M) | 9.3 GB | 40K |
| Llama 3.1 8B | llama3.1:8b (q4_K_M) | 4.9 GB | 128K |
| gpt-oss-20b | gpt-oss:20b (MXFP4) | 14 GB | 128K |

OpenAI says gpt-oss-20b "only requires 16GB" and "can run on edge devices with just 16 GB of memory" **[source]** (openai.com/index/introducing-gpt-oss/).

**[arithmetic]** Resident weights are taken as roughly the file size (llama.cpp memory-maps the GGUF and keeps it resident while loaded). This is an assumption, not a measurement.

### KV cache per agent context

Ollama: default context 4096 tokens; default KV type f16; `q8_0` about halves and `q4_0` about quarters KV memory (with Flash Attention); "a 2K context with 4 parallel requests will result in an 8K context and additional memory allocation"; models stay loaded 5 minutes by default **[source]** (docs.ollama.com/faq).

Architecture **[source]** (Hugging Face config.json): Qwen3-4B and Qwen3-8B 36 layers, 8 KV heads, head_dim 128; Qwen3-14B 40 layers, 8 KV heads, 128; Llama 3.1 8B 32 layers, 8 KV heads, 128 (unsloth mirror of Meta config); gpt-oss-20b 24 layers alternating 12 sliding-window (128 tokens) and 12 full attention, 8 KV heads, head_dim 64.

**[arithmetic]** f16 KV bytes per token = 2 (K,V) x layers x KV heads x head_dim x 2 bytes.

| Model | KV per token | 4K slot | 32K slot |
| --- | ---: | ---: | ---: |
| Qwen3 4B / 8B | 144 KiB | 576 MiB | 4.5 GiB |
| Qwen3 14B | 160 KiB | 640 MiB | 5.0 GiB |
| Llama 3.1 8B | 128 KiB | 512 MiB | 4.0 GiB |
| gpt-oss-20b | 24 KiB (full layers) + ~3 MiB fixed (sliding) | ~99 MiB | ~0.75 GiB |

Compute buffers and runtime overhead are extra and not counted.

### Apple Foundation Models (on-device ~3B)

**[source]** Apple ML Research, "Apple Intelligence Foundation Language Models Tech Report 2025 / updates": "approximately 3-billion-parameter model"; decoder weights 2 bits per weight (QAT); embedding table 4 bits; KV cache quantised to 8 bits; KV sharing between blocks "reducing the KV cache memory usage by 37.5%". No total RAM footprint is published.
**[source]** TN3193: context window of 4096 tokens per session.
**[source]** support.apple.com/en-us/121115: Apple Intelligence needs "up to 8 GB" of storage (up to 14 GB on newer devices with at least 12 GB unified memory); no RAM figure is given.
**[arithmetic]** 3B x 2 bits = 0.75 GB for decoder weights, plus a 4-bit embedding table of unpublished size, so roughly 1 GB resident is a plausible lower bound. Unverified.

### Chrome Gemini Nano

**[source]** developer.chrome.com/docs/ai/get-started: CPU path needs "16 GB of RAM or more and 4 CPU cores or more"; GPU path needs "strictly more than 4 GB of VRAM"; 22 GB free disk; not on Android or iOS. developer.chrome.com/docs/ai/understand-built-in-model-management names variants "such as 4B parameters" and "such as 2B parameters" chosen by a GPU benchmark. No RAM footprint is published. In practice an 8 GB laptop without a >4 GB-VRAM GPU does not get Gemini Nano at all.

### OS memory behaviour

**[source]** Apple `os_proc_available_memory`: returns "the current memory limit minus the memory footprint of your app"; limits "can change during the app life cycle and don't necessarily correspond to the amount of physical memory"; using all of it may make "the system ... terminate other apps and system processes". Entitlement `com.apple.developer.kernel.increased-memory-limit` raises the default limit "on supported devices" only. Neither page gives a number.
**[source]** Metal `recommendedMaxWorkingSetSize`: "An approximation of how much memory ... this GPU device can allocate without affecting its runtime performance." Apple does not publish the value; the often-quoted ~2/3 to 3/4 of unified memory on Macs is not from a primary source here.

## Harness RAM

**[source]** docs/waiting-agent-memory.md in the Rui repo (private memory, MB, median of 3, Linux, fake model that never answers, unequal feature sets, not macOS):

| Harness | 0 | 1 | 10 | 100 |
| --- | ---: | ---: | ---: | ---: |
| Rui | 1.7 | 2.2 | 2.2 | 2.5 |
| pi | 85.6 | 93.6 | 97.5 | 112.4 |
| Codex app-server | 14.7 | 25.5 | 49.6 | 206.5 |
| OpenCode | 174.2 | 529.8 | 556.7 | 650.7 |

**[estimate, unverified]** Claude Agent SDK and Codex SDK start one CLI process per agent. If a Node CLI costs ~100 to 200 MB private and a Rust CLI ~10 to 30 MB, 10 agents cost ~1 to 2 GB (Claude Agent SDK) or ~0.1 to 0.3 GB (Codex SDK), and 100 agents ~10 to 20 GB or ~1 to 3 GB. Another ticket measures these; replace these figures with its numbers.

## Model vs harness on 8 GB and 16 GB devices

**[arithmetic]** Model = Ollama weights + one f16 4K KV slot. Harness at 10 waiting agents.

| Device | Model (1 slot, 4K) | Rui | pi | Codex app-server | OpenCode | Claude Agent SDK (est.) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 8 GB | Qwen3 4B ~3.1 GB | 0.002 GB | 0.10 GB | 0.05 GB | 0.56 GB | 1 to 2 GB |
| 8 GB | Llama 3.1 8B ~5.4 GB | same | same | same | same | same |
| 8 GB | Apple FM ~1 GB (arith., unverified) | same | same | same | same | same |
| 16 GB | Qwen3 8B ~5.8 GB | same | same | same | same | same |
| 16 GB | Qwen3 14B ~9.9 GB | same | same | same | same | same |
| 16 GB | gpt-oss-20b ~14.1 GB | same | same | same | same | same |

Each extra agent generating concurrently: +0.5 to 0.64 GB (4K, f16) on the dense 8B/14B models, ~0.1 GB on gpt-oss-20b. Per extra waiting agent, harness cost: Rui ~kilobytes, pi ~0.2 MB, Codex app-server ~1.8 MB, OpenCode ~1.4 MB (from the 10 to 100 slope).

## What the saving buys

- **Bigger model:** no, not against pi or Codex app-server. The 8B to 14B Q4 step costs ~4.1 GB of weights plus ~0.06 GB per KV slot; Rui saves 0.05 to 0.2 GB against those harnesses, which is 1 to 5% of the step. Against OpenCode, the 0.55 to 0.65 GB saving is ~15% of the step: it can be the margin on a tight 16 GB machine, but it does not decide the step on its own. Against one-Node-CLI-per-agent SDKs at 10+ agents (estimated 1 to 2 GB at 10), the saving could be the margin that lets 14B fit beside them; this rests on the unverified estimate.
- **More agents at once:** the limit is KV slots and throughput on the model server, not the harness. With Ollama, agents beyond `OLLAMA_NUM_PARALLEL` queue for a slot; queued agents cost only harness memory. So for 100 agents against one local model, Rui keeps 100 *waiting* agents for 2.5 MB where pi/Codex app-server need 0.1 to 0.2 GB and OpenCode 0.65 GB, but only ~1 to 4 of them generate at once on a 16 GB machine whichever harness is used. The saving is about one extra 4K KV slot against OpenCode, and less than one against pi or Codex app-server.
- **Plainly:** for a single on-device model on an 8 to 16 GB device, Rui's memory advantage is visible only against OpenCode and per-process SDKs; against pi and Codex app-server it is below the noise of choosing a context length or KV quantisation (switching KV f16 to q8_0 on one 4K slot saves ~0.29 GB, more than Rui saves against pi at 100 agents).

## Unverified

- Resident RAM equals GGUF file size; runtime compute buffers ignored.
- Apple Foundation Models RAM (~1 GB lower bound) is arithmetic on a partly unpublished size; Apple publishes no footprint.
- Gemini Nano RAM footprint is not published.
- Harness figures are Linux, waiting on a fake model; macOS and active workloads may differ.
- Claude Agent SDK and Codex SDK per-agent figures are estimates pending the sibling ticket.
- No macOS Metal working-set limit or iOS per-app jetsam number comes from a primary source.
