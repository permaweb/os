# Qwen GGUF runtime decision

## Prompt

After the initial AndEE `inference@1.0` implementation, demonstrate Gemma 4
and the largest Unsloth Qwen3.5 27B quantization that genuinely works within a
16 GiB Android RAM budget, before touching the real phone.

## Issue

The existing Android provider consumes `.litertlm` packages through
LiteRT-LM. Unsloth publishes the requested 27B quantizations as GGUF, and no
supported Qwen3.5 27B LiteRT-LM package or conversion path exists. A host-only
or standalone CLI generation would not demonstrate compatibility with the
provider Ouroboros uses.

## Options

1. Stop at a standalone llama.cpp experiment. This measures fit and decode,
   but does not satisfy the provider contract or Ouroboros tool path.
2. Convert the model to LiteRT-LM. There is no supported conversion route for
   this architecture, and current LiteRT-LM Qwen3.5 initialization remains an
   upstream compatibility problem.
3. Add a measured, Android-private `llama-cpp` runtime behind the existing
   broker and `inference@1.0` device. A pinned `llama-server` child can use its
   GGUF-native chat template and OpenAI tool parser, while remaining killable
   independently of the AndEE service.

## Decision

Use option 3. Add a required per-model runtime (`litert-lm` or `llama-cpp`),
allow GGUF only for the CPU-only llama runtime, and keep the public Erlang
device and Android broker protocol unchanged. Package a checksum-pinned
official Android arm64 llama.cpp build, expose it only on an app-private Unix
socket, and proxy only validated chat-completion requests. No model, URL,
arbitrary command-line arguments, TCP listener, built-in agent tools, MCP, or
application source enters the APK.

This is the smallest reversible change that satisfies the request while
preserving the AndEE/application boundary. Acceptance requires real structured
tool calls and continuation—not merely text generation—and measured guest
memory with a conservative pre-launch reserve.

## Outcome

The 12,289,423,264-byte Q3_K_S file is the largest published Unsloth
Qwen3.5-27B quantization below the emulator's measured ceiling of physical RAM
minus 4 GiB. Q3_K_M and Q4_K_M are rejected before process launch. A cold
16,384-token-context run completed three structured calls at 3.50--3.62 decode
tokens/s, reached 14,126,208 KiB RSS, and used 576,512 KiB of Android zram.
Android's ordinary compressed swap activity means "zero swap growth" is not a
sound acceptance invariant; the enforced invariant is the measured physical
RAM gate plus the 4 GiB reserve, followed by real cold-run RSS, zram, LMK, and
completion evidence.

The runtime was then composed into Ouroboros without any Ouroboros source or
APK input. A browser-authored turn called `List`, consumed the real tool result,
called `Send`, and rendered `QWEN-27B-ANDEE-OK` in `#general`.
