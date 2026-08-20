# AndEE local inference status

- Base: `9289217761705e7e4d152b7d012bb288255614b3`
- Branch: `feat/andee-mobile-tpu-inference`
- Mode: unattended
- Acceptance: real Gemma generation through `inference@1.0` on the emulator,
  followed by a separately witnessed Tensor G5 NPU run on Pixel 10 Pro Fold.

## Current

- Confirmed Ouroboros has one replaceable `inference@1.0` device contract;
  providers are configurations, not separate devices.
- Confirmed current Android path is LiteRT-LM. NNAPI is deprecated.
- Confirmed emulator cannot expose a mobile NPU. Emulator validation must use
  explicit CPU/GPU mode and must not be reported as TPU evidence.
- Confirmed Google Tensor SDK supports AOT Gemma 3 1B on Tensor G5, including
  Pixel 10 Pro Fold.
- Implemented the AndEE-only AO device, same-UID Android inference broker,
  digest-locked model catalogue, serialized LiteRT-LM engine, measured
  CPU/GPU/NPU selection, and pinned Google Tensor dispatch runtime.
- Hardened the OpenAI-compatible contract: strict named/required/none tool
  choice, decode-count-based `length` termination, reasoning-channel
  round-tripping, explicit rejection of unsupported stop sequences, and the
  standard inference request observer hook.
- Health now distinguishes statically configured models from engines that
  actually initialized. NPU responses report a requested backend and do not
  claim effective TPU delegation that LiteRT-LM cannot expose.
- Kotlin compilation and the Android debug unit-test suite pass against pinned
  `litertlm-android:0.16.1`. The same-UID inference service bounds concurrent
  requests while serializing model generation. Total request and shutdown
  deadlines cancel cooperatively, then fail closed through an app-process
  watchdog that first terminates the separately spawned HyperBEAM runtime.
- Android device validation passes: 42 overlay EUnit tests, 8 packaged
  `inference@1.0` tests, and both generic package boundary scans.
- A full runtime/APK build and generic-artifact scan pass. No model or
  Ouroboros source/archive is present in the APK or runtime ZIP.
- Real LiteRT-LM FunctionGemma 270M Q8 inference passes on the isolated API 35
  emulator in explicit CPU mode. The completion returns a parsed `Send` tool
  call, requested backend `cpu`, and the verified model digest. A one-token
  required-tool request returns `finish_reason: length` for Ouroboros to
  resume. The emulator-only APK records both native dependency digests and
  rebuilt byte-identically as
  `1c7dce9c29e233e6950b26d4418767bbae73a887b1dc810e8de765b41cf6c509`.
- Ouroboros was composed at runtime through published device ids and measured
  provider configuration, with no Ouroboros changes or APK build input. Its UI
  lists `local/functiongemma-mobile-actions` and shows real FunctionGemma
  reasoning plus a completed structured `List` tool call.
- Full-agent Ouroboros input is larger than the available FunctionGemma
  artifact's fixed 1024-token KV cache. A UI member restricted to one small
  tool fits and demonstrates the complete UI/device/model path with a
  completed `List` invocation and result. Its post-tool continuation can still
  exceed that fixed cache; the direct provider proof remains independently
  successful. A separate ungated Qwen3 0.6B 4096-context control fits the full
  default agent prompt and reaches Ouroboros tool dispatch.
- Apple's ARM64 Android emulator falsely advertises SME/SME2, triggering the
  known XNNPACK `rdsvl` crash in the official JNI. Emulator evidence uses an
  exact, revision-pinned LiteRT-LM 0.16.1/XNNPACK source build with SME
  disabled. A dedicated target builds, checksum-verifies, signs, and scans that
  emulator-only APK. The release APK keeps Google's unmodified,
  checksum-verified binaries.

## External gate

- The official Tensor G5 AOT artifact remains license-gated. The later Pixel
  10 Pro Fold proof requires the operator-provisioned artifact and an explicit
  witnessed physical-device run. No connected physical device was accessed or
  modified during emulator validation.

## Completed model expansion

- Acceptance: before touching the real phone, demonstrate the official Gemma 4
  mobile family and the largest Unsloth Qwen3.5 27B GGUF quantization that can
  genuinely initialize and generate inside a 16 GiB Android guest budget.
- Physical devices and the two pre-existing shared emulators remain strictly
  out of scope. All experiments use a newly started, explicitly addressed AVD.
- Official public Apache-2.0 Gemma 4 E2B and E4B LiteRT-LM artifacts both pass
  real emulator generation against the final reproducible APK, named `Send`
  tool parsing, and the one-token `finish_reason: length` control through the
  same provider. Only E2B currently has an official Tensor G5 AOT artifact;
  E4B remains CPU/GPU-only on the planned phone test.
- Added a generic measured `llama-cpp` runtime behind the unchanged
  `inference@1.0` device for CPU-only GGUF models. The pinned official b10502
  Android arm64 server runs as a separately killable child on an app-private
  Unix socket. Caller-controlled paths, URLs, command arguments, TCP, MCP, web
  UI, and built-in agent features are not exposed.
- The 12,289,423,264-byte Unsloth Qwen3.5-27B Q3_K_S quantization is the largest
  published 27B file that passes the measured physical-RAM plus 4 GiB reserve
  gate on the 16 GiB guest. It generated the exact named `Send` call three
  times at 3.50--3.62 decode tokens/s, passed tool-result continuation and
  `length` handling at a 16,384-token context, and reached 14,126,208 KiB RSS
  with 576,512 KiB of Android zram in the cold-run evidence.
- The next larger Q3_K_M and Q4_K_M artifacts fail the physical-memory gate
  before a child is launched. The Q4_K_M rejection is externally recorded:
  16,740,812,704 model bytes plus the 4 GiB reserve exceeds the guest's
  16,750,374,912 physical bytes.
- Ouroboros was composed at runtime against Q3_K_S. From the real browser UI,
  the 27B member consumed a 1,465-token agent prompt, called `List(scope=all)`,
  consumed its 3,099-token continuation, called `Send(to=#general)`, and the
  channel rendered `QWEN-27B-ANDEE-OK`. The visible channel and complete tool
  trace are saved under
  `arch/android/build/model-expansion/qwen35-ouroboros-ui/`.
- Two consecutive complete builds produced byte-identical emulator APKs with
  SHA-256 `e7943f4d5819db4fb828c7e0cc0d9f4f62ebde1a8f390b91f705e9a05f16c0ae`.
  That exact APK then passed a fresh direct Q3_K_S tool call, continuation, and
  `length` smoke. It also ran a new browser-authored Ouroboros workspace turn,
  completed `Send(to=#general)`, and rendered
  `QWEN-27B-REPRODUCIBLE-APK-OK`; the digest-bound screenshots, DOM snapshots,
  health response, and server timing log are in the same UI evidence folder.
- The GGUF catalogue fails closed before launch unless the model file plus
  4 GiB of Android/HyperBEAM/compute headroom fits measured physical RAM.
