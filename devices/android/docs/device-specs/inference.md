# `andee-inference@1.0`

`andee-inference@1.0` runs a measured local model through an app-private
Android broker. It is an application-agnostic provider for a generic
`inference@1.0` multiplexer and implements the non-streaming OpenAI
chat-completion shape used by AO agents.
Measured model entries select either LiteRT-LM (`.litertlm`) or the pinned
llama.cpp GGUF runtime; the public device contract does not change with the
runtime.

## Public keys

| Key | Meaning |
|---|---|
| `completions` | Execute a non-streaming chat-completion request. |
| `chat` | Alias for `completions`. |
| `models` | Return configured, compatible models in OpenAI catalogue form. |
| `health` | Return configuration, initialization, backend, SoC, and model evidence. |
| `v1` | Normalize nested `/v1/...` AO routes. |

`stream=true`, caller-supplied stop sequences, explicit reasoning/thinking or
penalty controls, and `tee=true` are rejected rather than silently ignored. AndEE
attestation for inference responses is not part of this device revision. The Android
runtime may consume incremental model output internally, but the AO response
is buffered into one completion. Named, required, and `none` tool choices are
enforced after generation. LiteRT-LM decode counters distinguish token-limit
termination (`length`) from a model stop, so an agent can resume truncated
output. Model reasoning channels are returned as visible reasoning and
round-tripped exactly in `reasoning_details`.

The backend is part of each measured model entry and a request cannot override
it. This permits one provider to expose an NPU AOT model and a small CPU model
without a global backend switch. A model name selects only an allowlisted entry
in the effective boot configuration. Its `model-id` is a 43-character Arweave
network transaction ID; callers can never select a host path or URL.

The effective boot configuration owns the public catalogue:

```json
{
  "inference-providers": {
    "local-andee": {
      "inference-device": "andee-inference@1.0",
      "default-model": "gemma-4-e2b-it-tensor-g5",
      "models": [
        {
          "id": "gemma-4-e2b-it-tensor-g5",
          "model-id": "eq7Oh5TPjLMvEwpw7vlRtTsArjfYiCNCTAE3d3XhTIo",
          "bytes": 3113545589,
          "sha256": "rxCCmGY57N59uV2Rvm_lT4trRYEEc0xbr8IE5p1oUtw",
          "runtime": "litert-lm",
          "backend": "npu",
          "soc-models": ["Tensor G5"],
          "max-context-tokens": 2048,
          "max-output-tokens": 128
        },
        {
          "id": "functiongemma-mobile-actions",
          "model-id": "wV_QpsZwdNW09poKoOCyo38BCx5Pg64aajoQTEao0d0",
          "bytes": 284426240,
          "sha256": "khCWlfkR0YcvqK4HweP_DtcPLD0WkNQQ7G24WHwqtAk",
          "runtime": "litert-lm",
          "backend": "cpu",
          "max-context-tokens": 1280,
          "max-output-tokens": 64
        }
      ]
    }
  }
}
```

The broker resolves `$gateway/<model-id>`. That transaction may be the model
data itself or a `permawebos/andee-model/1` manifest containing an ordered,
bounded list of Arweave chunk IDs. It streams the resulting bytes into an
ID-derived app-private path, verifies the measured whole-model byte length and
base64url SHA-256, and only then atomically makes it available to a runtime. This is a
materialization detail: host filenames are neither configuration nor part of
the public device contract, and models are not APK or OS-image assets.
`litert-lm` entries are materialized as `.litertlm`. `llama-cpp` entries are
materialized as `.gguf`, are ARM64 CPU-only, and run as a long-lived child on a
second app-private filesystem Unix socket. The pinned server has no TCP
listener, Web UI, model router/download path, built-in agent tools, MCP, or
arbitrary operator arguments. Android can terminate the child independently
of the broker if model initialization or generation fails. AndEE reserves 4
GiB of physical memory for Android, HyperBEAM, KV/compute state, and lifecycle
headroom; GGUF data larger than the remaining measured `MemTotal` budget is
rejected before the child starts.

The generic LiteRT-LM path is validated with the official Apache-2.0 Gemma 4
E2B and E4B CPU packages at repository revisions
`6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94` and
`2eee7ac325f20eb8c9ac1d0e972f7c84663062da`. The generic E2B file is
2,588,147,712 bytes with base64url SHA-256
`GBk4EF4O79EFlhQX6Np1kD6s2hAsT86c6Q9QuXE5pjw`; E4B is 3,659,530,240 bytes
with digest `CyqJgM4VX9l2c9joILTSnZx9mbj6aAb0JdlpsUW9UuA`.
E4B remains a supported operator-configured CPU/GPU model, but it is not one
of the two default network model entries and has no official Tensor G5 AOT
artifact. These are network-resolved models, not APK assets.

The same E2B revision publishes the 3,113,545,589-byte Tensor G5 AOT artifact
shown above. Its SHA-256 is
`af1082986639ecde7db95d91be6fe54f8b6b458104734c5bafc204e69d6852dc`.
Physical acceptance on a Pixel 10 Pro Fold returned the named tool call and
`length` control while atrace recorded the Tachyon compute session and TPU
allocation. The APK declares the Pixel's optional public
`libedgetpu_litert.so` runtime and fails closed if it cannot be loaded. No
official Tensor G5 AOT E4B artifact currently exists, so E4B must not be
advertised as NPU-capable.

NPU models must match the current Google
Tensor SoC, the pinned runtime's Tensor G3–G6 support, and the dispatch runtime
packaged with the measured APK. The
current LiteRT-LM Kotlin API reports the requested NPU backend but not
effective delegation and may retain CPU-side partitions. Consequently,
`npu-execution-verified` remains false: engine initialization proves runtime
readiness, not TPU execution. Pixel 10 Pro Fold (Tensor G5) acceptance requires
a witnessed device trace or hardware counter; the provider does not
manufacture that evidence from successful generation.

Health is `configured` once the model digest and static runtime tuple pass. It
becomes `healthy` only after the matching LiteRT-LM engine initializes or the
matching llama.cpp child reports ready. Model
entries likewise keep `ready=false` until that initialization succeeds.

The private broker protocol is four-byte length-framed JSON over a filesystem
Unix socket. Android checks that each peer has the app UID. This JSON is a
private Android edge, not a second public inference protocol.

Requests are serialized and have a ten-minute end-to-end deadline, including
queueing, any first-use network materialization, digest verification, backend
initialization, and generation, because one local request can consume most of
a phone's accelerator and memory. The Android deadline leaves ten seconds for
the AO transport to return its error. Cancellation runs off the request and
Android lifecycle threads; if vendor native code does not quiesce, AndEE
terminates its child HyperBEAM runtime and hard-resets the app process after
emitting the timeout so a wedged driver cannot permanently block service
restart. The process-isolated GGUF runtime instead closes the active request
socket and forcibly terminates its exact child process. Every LiteRT-LM engine
shutdown has the same bounded watchdog. The
route inherits the node's measured HTTP access policy; the device does not add
its own authentication layer. Operators exposing a configured model must set
that policy appropriately. Callers can cause only a measured `model-id` to be
materialized; they cannot provide a URL or host path, obtain identity
signatures, or downgrade the measured backend.
