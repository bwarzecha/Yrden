# Local Model KV Cache Behavior

## Overview

When using Yrden's agent loop with local models via LM Studio (or any llama.cpp-based server), KV cache prefix reuse is critical for performance. Without it, every agent iteration reprocesses the entire conversation from scratch, causing response times to scale linearly with context size.

## How KV Cache Prefix Reuse Works

llama.cpp's server maintains a KV cache per slot. When a new request arrives:

1. The server tokenizes the new prompt
2. It compares the token sequence against the cached slot
3. If a prefix matches, it reuses the cached KV tensors and only processes new tokens
4. If no match, it processes the entire prompt from scratch

Key server parameters:
- **`cache_prompt`**: Enables KV cache reuse (default: true)
- **`-np`**: Number of parallel slots (context is divided among them)
- **`-sps`**: Slot prompt similarity threshold (default: 0.5 = 50% match required)
- **`--cache-reuse`**: Min chunk size for cache reuse via KV shifting

Reference: [llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

## Hybrid/Recurrent Models Do NOT Support Cache Reuse

Models with recurrent (linear) layers — such as **qwen3-coder-next**, **qwen3-next**, and other hybrid architectures — cannot benefit from KV cache prefix reuse.

### Why

Traditional transformer attention layers store key/value pairs per token position. These can be cached and reused when the token prefix matches.

Recurrent layers maintain a **single evolving state** updated sequentially for each token. There is no way to skip ahead — the state at position N depends on processing all tokens 0..N-1 in order. There is no "prefix" to match against.

### Impact

Every agent iteration reprocesses the **entire** conversation history. With a 45K token context, this means 170-200 seconds per iteration on consumer hardware, even though only ~200 new tokens were added.

### Upstream Issue

[ggml-org/llama.cpp#18497](https://github.com/ggml-org/llama.cpp/issues/18497) — "Eval bug: cache-reuse not effective in qwen3-next"

> "Recurrent layers don't have a KV cache. They use a single recurrent state which is updated for each token. [...] These flags [--cache-reuse, --swa-full] do not do anything for recurrent models."

A proposed fix (recurrent state checkpointing at intervals) is not yet implemented.

## Recommended Models for Local Agent Testing

Use **pure transformer** models that benefit from KV cache prefix reuse:

| Model | Architecture | Cache reuse |
|-------|-------------|-------------|
| Llama 3/4 | Transformer | Yes |
| Mistral / Mixtral | Transformer | Yes |
| Qwen3 (standard) | Transformer | Yes |
| Qwen3-Coder | Transformer | Yes |
| **Qwen3-Next** | **Hybrid (recurrent)** | **No** |
| **Qwen3-Coder-Next** | **Hybrid (recurrent)** | **No** |

The "Next" suffix in Qwen3 model names indicates the hybrid architecture. Avoid these for multi-turn agent workloads.

## What Yrden Sends

Yrden's agent loop (via `AgentIterator.callModel()`) rebuilds the full message array on each iteration:

```
[system_prompt, user_msg, assistant_msg_1, tool_result_1, assistant_msg_2, tool_result_2, ...]
```

With a pure transformer model and proper caching, only the newly appended messages need processing. With a hybrid model, the entire sequence is reprocessed every time.

## Verified Behavior (2026-02-09)

Tested with qwen/qwen3-coder-next via LM Studio, using `max_tokens=1` to isolate prompt processing time:

| Request type | Prompt tokens | Cold | Warm | Speedup |
|---|---:|---:|---:|---:|
| Simple (system+user) | 883 | 4.49s | 2.88s | 1.6x |
| 1 tool round | 6,741 | 13.85s | 17.08s | 0.8x |
| 2 tool rounds | 6,821 | 0.24s* | 22.47s | 0.0x |

\* Hit residual cache from preceding request with same prefix.

Multi-turn requests show no caching benefit — warm is actually slower than cold, confirming full reprocessing on every request.
