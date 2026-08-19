# AndEE local inference provider

## Original prompt

Build an application-agnostic, Ouroboros-compatible `inference@1.0` provider
that performs local inference on AndEE hardware with mobile TPU/NPU execution.
Keep persistent changes inside AndEE-specific source and demonstrate real
Gemma in the emulator before a witnessed Pixel Fold hardware test.

## Issue

Ouroboros does not define separate provider devices. Its `agent@1.0` always
resolves one device named `inference@1.0`; the existing implementation then
multiplexes OpenAI, Anthropic, and OpenAI-compatible local HTTP services.
Android likewise has no generic "NPU SDK": new execution uses LiteRT, with
LiteRT-LM providing the LLM pipeline and vendor dispatch libraries providing
NPU execution.

An Android emulator cannot expose Google Tensor hardware. Google Tensor NPU
LLMs are AOT-compiled for the exact SoC, while the emulator can run the same
LiteRT-LM API only on CPU/GPU.

## Options

1. Run an OpenAI-compatible loopback HTTP server in the Android app and retain
   Ouroboros's provider-multiplexing device.
2. Package an independent AndEE `inference@1.0` implementation and connect it
   directly to a same-UID Android inference broker.
3. Run LiteRT-LM inside the generic Andock guest.

Option 1 adds an unnecessary network protocol and retains an application
package as the owner of a platform capability. Option 3 cannot safely expose
vendor NPU libraries to the isolated guest and confuses PRoot with the Android
hardware boundary.

## Decision

Use option 2. The AO device owns only the portable `inference@1.0` request and
response contract. A length-framed app-private Unix socket carries sanitized
JSON to a same-UID Kotlin broker, following AndEE's existing crypto and Andock
patterns. LiteRT-LM remains an Android implementation detail.

The measured default accelerator request is NPU. CPU/GPU are explicit
development modes used by the emulator, and an inference request cannot change
the backend. LiteRT-LM 0.16.1 does not expose effective partition delegation
and its NPU path permits CPU-side work, so a successful completion is not
reported as TPU proof. Health identifies static configuration separately from
successful engine initialization; completion responses identify only the
requested backend, model digest, SoC, and runtime tuple. A witnessed Pixel 10
Pro Fold trace/counter remains the NPU acceptance boundary.

Models are app-private runtime composition, not APK assets. Requests select a
catalogued model id, never an arbitrary filesystem path. The model catalogue
uses Ouroboros's existing `local/<model>` provider namespace, keeping the UI
compatible without making the device specific to Ouroboros.

The public LiteRT-LM Android artifact and LiteRT Google Tensor dispatch runtime
are version- and checksum-pinned. The proprietary Tensor SDK/compiler and its
terms are not vendored into this repository; the later hardware validation is
an evaluation workflow, not a claim of redistributable production support.
