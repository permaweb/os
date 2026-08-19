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
