# Qwen3.8 LiteRT-LM conversion decision

## Prompt

Demonstrate the largest 2- or 3-bit Unsloth Qwen3.8-27B Dynamic 3.0 GGUF that
works through the existing Android llama.cpp provider with system headroom,
then work unattended to create and test an Android-ready LiteRT-LM conversion.
Do not publish, message anyone, spend money or API tokens, affect production,
or harm existing work.

## Observed inputs

- GGUF repository revision:
  `unsloth/Qwen3.8-27B-GGUF@27af057ecb382ddfea5d12837360a8980560e3ed`.
- `UD-IQ3_S`: 12,040,883,104 bytes, SHA-256
  `d847e2c1e4aa276e4b7b8e9ad7628050e61e165d49ab995407bc36677a6f3864`.
- `UD-IQ3_XXS`: 10,934,860,704 bytes, SHA-256
  `c0b7c3038681ed2e3040456c1dd45f9858b6c2290bed172c70388a94874f3eee`.
- Architecture: `Qwen3_5ForConditionalGeneration`, 64 layers alternating
  Gated DeltaNet and full attention, 5120 hidden width, 248,320 vocabulary,
  one MTP layer, native multimodality, and 262,144 native context.
- Existing AndEE runtime pin: llama.cpp b10502 at
  `0adcc3bb571011bff8b91335d0728a82845c421b`; LiteRT-LM 0.16.1 at
  `924e79c91542761242244e4f1651851f822e4cbb`.

## Decision

Run one-variable gates in this order:

1. Prove the exact b10502 runtime can parse and generate from each new GGUF on
   the host or Android before changing the provider. If it cannot, advance to
   the smallest newer llama.cpp revision that explicitly supports Qwen3.8,
   pin every downloaded binary/source hash, and keep the provider protocol
   unchanged.
2. Try `UD-IQ3_S` first as the highest-quality 3-bit candidate, but retain the
   4 GiB Android/HyperBEAM/runtime reserve as an invariant. Use `UD-IQ3_XXS`
   when the exact physical `MemTotal` gate rejects IQ3_S. Admit either only if
   measured cold/warm RSS, zram, process survival, tool continuation, and
   Ouroboros execution support it.
3. Treat GGUF and LiteRT-LM conversion as separate formats, not a byte-level
   transcode. Start from the revision-pinned Hugging Face weights and config,
   trace the public LiteRT Torch/CLI exporter and quantizer, then reproduce the
   official `.litertlm` container sections and model-specific metadata.
4. A built `.tflite` graph is an intermediate result. Acceptance requires an
   assembled `.litertlm` that the pinned LiteRT-LM runtime initializes and
   executes on the dedicated Android AVD through the public AndEE route.
5. NPU AOT compilation is attempted only through public local tooling. If the
   Google Tensor compiler or Qwen3.8 operator lowering is unavailable, record
   the exact first unsupported boundary and retain an honest CPU-ready package
   rather than manufacturing NPU evidence.

This preserves the application-agnostic device boundary and makes each
conversion claim falsifiable by a real packaged runtime.

## Experimental results

- The exact `UD-IQ3_S` GGUF passes the complete Android provider contract on a
  dedicated 16 GiB AVD. The physical Fold reports 16,331,776,000 bytes, making
  IQ3_S plus the 4 GiB reserve 4,074,400 bytes too large. The real provider
  records `llama-cpp-insufficient-memory` before child launch. Physical testing
  therefore advances to the exact 10,934,860,704-byte `UD-IQ3_XXS` artifact.
- A single file-backed FP32 LiteRT graph avoids the otherwise fatal source plus
  static-model duplication. The graph is 107,637,793,024 bytes and can be
  requantized repeatedly from pinned local inputs.
- LiteRT's blockwise INT2 representation is rejected by the Android XNNPACK
  delegate. Its channelwise dynamic INT2 representation executes, but direct,
  decomposed-Hadamard, and progressively protected recipes have so far emitted
  repetitive or empty text. Weight-only INT2 dequantization exceeds the 16 GiB
  process budget during generation.
- Unsloth documents Dynamic 3.0 as model-specific PTQ driven by a new
  agentic/chat/multilingual importance-matrix corpus, improved layer selection,
  and additional quantization techniques. The current converter reproduces the
  exact GGUF tensor-by-tensor precision plan, but LiteRT's uniform INT2/INT4
  kernels do not reproduce llama.cpp IQ codebooks or the unpublished Qwen3.8
  importance statistics. A package of the right size is therefore not expected
  to inherit the GGUF's quality automatically.
- The direct greedy float-TFLite verifier was stopped after it proved
  pathologically inefficient and provided almost no observable progress. It
  is retained only as a diagnostic control, not the primary conversion
  workflow, and must not be restarted as a brute-force full-model decode.
  Further conversion work must first derive a bounded, observable layerwise or
  reduced-graph validation path that localizes export versus quantization
  errors without repeatedly interpreting the entire 107 GB graph.
- The public NPU compiler implementation contains Qualcomm and MediaTek paths
  and an explicit Google Tensor TODO. Tensor G5 custom AOT output therefore
  cannot be produced through the public toolchain today; the CPU package and
  this compiler boundary must remain separately reported.
- Qwen3.8's revision-pinned Jinja template emits native XML tool frames of the
  form `<tool_call><function=name><parameter=key>...`, while both LiteRT-LM
  0.16.1 and current upstream main still route Qwen through a JSON-only Qwen3
  processor. If coherent generation passes, package the model with the generic
  data processor so the raw native frame survives, then parse and allowlist it
  at the application-agnostic Android provider boundary. Plain-text success is
  not sufficient for the `inference@1.0` acceptance gate.
