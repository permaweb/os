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
- Confirmed the official Gemma 4 E2B catalogue includes a Tensor G5 AOT model;
  E4B currently has generic CPU/GPU packages but no Tensor G5 package.
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

## Physical-device acceptance in progress

- The operator explicitly authorized the connected physical-device run on
  2026-08-20. The exact target is ADB serial `58281FDCG0028W`, a Pixel 10 Pro
  Fold (`rango`) reporting Tensor G5, API 37, 15,949,000 KiB physical RAM, and
  360,637,520 KiB free `/data` space. Every command is serial-qualified; the
  shared emulators remain untouched.
- Smallest-to-largest physical controls now pass through public
  `~inference@1.0`: FunctionGemma 270M Q8, Gemma 4 E2B CPU, and Gemma 4 E4B
  CPU all return the exact named `Send` tool call and the resumable one-token
  `finish_reason: length` control. The CPU process maps contain neither the
  Google Tensor dispatcher nor the southbound runtime.
- The official Apache-2.0 Gemma 4 E2B Tensor G5 AOT artifact now passes real
  NPU execution. Its exact digest is
  `af1082986639ecde7db95d91be6fe54f8b6b458104734c5bafc204e69d6852dc`;
  completion and truncation controls both return HTTP 200. Atrace records a
  `com.google.edgetpu.tachyon.IComputeService` session, `MainTpuActor`, and
  `AllocateTpu_Init`, while LiteRT reports one of one decode nodes replaced by
  `DispatchDelegate`. E4B has no official Tensor G5 AOT artifact and must not
  be relabelled as NPU execution.
- The first G5 attempt exposed the packaged dispatcher but could not resolve
  the Pixel southbound runtime. The root cause was Android's target-SDK native
  library allowlist: the APK had not declared the otherwise public
  `libedgetpu_litert.so`. Commit `7e2bfae3` adds the optional manifest
  capability, a fail-closed preload, and an APK release check. The rebuilt APK
  and unit suite pass, and the physical rerun proves the fix end to end.
- Next run the exact Qwen3.8-27B `UD-IQ3_XXS` GGUF through the isolated
  llama.cpp CPU child. The phone began with only 3,624,592 KiB MemAvailable
  and 2,055,168 KiB free zram, so acceptance requires observed process
  survival, LMK/RSS/swap evidence, tools, continuation, and `length`.
  Unrelated phone processes will not be killed.
- The exact installed debug APK is SHA-256
  `32736d600cd45c4881f8b32aa79abf90fa912ad6656f457eee192eb2941bf680`;
  the hash of the installed `/data/app/.../base.apk` matches byte-for-byte.
  The package scan passed and the installed artifact contains the official
  LiteRT-LM JNI, Google Tensor dispatcher, and isolated llama.cpp runtime.
- The physical evidence is retained under
  `arch/android/build/model-expansion/`; the successful G5 run is
  `gemma4-e2b-tensor-g5-physical-npu-manifest/` and is bound to the exact
  installed APK, model digest, device identity, completion, memory snapshots,
  process maps, logs, and atrace.
- The phone reports 16,331,776,000 physical bytes. `UD-IQ3_S` plus the enforced
  4 GiB system reserve is 16,335,850,400 bytes, so this exact phone must reject
  IQ3_S before launch by 4,074,400 bytes. Preserve that physical negative
  control and move to `UD-IQ3_XXS` (10,934,860,704 bytes; 5,396,915,296 bytes
  remain for Android, HyperBEAM, KV/compute, and runtime overhead) rather than
  weakening the measured reserve.

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

## Active Qwen3.8 conversion mission

- Correction: the requested model is the real, newly published
  `unsloth/Qwen3.8-27B-GGUF`, not Qwen3.5. The exact public repository revision
  under test is `27af057ecb382ddfea5d12837360a8980560e3ed` (Apache-2.0).
- The exact 12,040,883,104-byte `UD-IQ3_S` artifact passes the dedicated
  16 GiB AVD, but the physical Fold reports only 16,331,776,000 bytes. The
  model plus the enforced 4 GiB reserve exceeds that by 4,074,400 bytes, and a
  real physical negative control returns `llama-cpp-insufficient-memory`
  before any child starts. The selected physical candidate is therefore the
  10,934,860,704-byte `UD-IQ3_XXS`, not IQ3_S.
- Critical overnight gate: derive a local, reproducible Qwen3.8-27B LiteRT-LM
  conversion and packaging path from public source and the official Gemma 4
  E4B package; test the resulting `.litertlm` on Android rather than treating
  container assembly or desktop export as success.
- Required LiteRT-LM behavior is text generation, the native Qwen data
  processor/chat template, structured tool calls, tool-result continuation,
  correct `length` termination, digest-bound model selection, and honest CPU,
  GPU, or NPU evidence. A Tensor-G5 AOT claim requires real compiler output and
  later physical-device execution; CPU validity alone must not be relabeled as
  TPU support.
- The exact Apache-2.0 BF16 source revision
  `3ea932cee0a432ae86e9c7826cbe8aef52323a28` has been exported with pinned
  LiteRT Torch `b66af07f...` and AI Edge Quantizer `a8956f3...`. The
  memory-bounded path creates one 107,637,793,024-byte file-backed FP32 graph,
  then requantizes it without reloading or duplicating the 27B checkpoint.
- Five real Android low-bit controls have initialized and executed but failed
  semantic quality: direct dynamic INT2, blockwise INT2 (unsupported by the
  XNNPACK runtime), all-INT2 Hadamard, signal-path-protected INT4, and
  IQ3-sensitive down-projection INT4. A weight-only INT2 graph instead crossed
  the 16 GiB memory boundary and was killed by Android LMKD. These are retained
  as negative evidence; container creation and runtime initialization are not
  being mistaken for a working model.
- The public LiteRT NPU compiler currently targets Qualcomm and MediaTek only;
  Google Tensor exposes the AOT runtime/dispatcher but no public custom-model
  compiler. A CPU-ready Qwen package is locally attainable, but a Qwen Tensor
  G5 AOT package is blocked at that public compiler boundary. Official Gemma 4
  E2B remains the later G5 NPU acceptance model; official E4B is CPU/GPU-only.
- Official Gemma 4 E4B is supported and already passes real LiteRT-LM CPU
  inference in the owned emulator. The validated Apache-2.0 artifact is
  `gemma-4-E4B-it.litertlm` at revision
  `2eee7ac325f20eb8c9ac1d0e972f7c84663062da`, 3,659,530,240 bytes, SHA-256
  `0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0`.
- Constraints: no publication, external messages, paid APIs/cloud compute,
  production changes, or changes outside the AndEE implementation/work logs.
  Physical-device access is now explicitly authorized for the connected Fold;
  shared emulators `emulator-5570` and
  `emulator-5582` remain untouched. Task-owned downloads, AVDs, ports, build
  trees, and processes must be digest-recorded and cleaned or explicitly
  retained as local evidence.

## Completed AndEE build-cycle deep clean

- Product surface: `make -C arch/android apk` must produce the same generic,
  verified AndEE APK with pinned HyperBEAM, platform-only devices, Andock,
  LiteRT-LM/Google Tensor NPU, llama.cpp, notices, and signature checks.
- Baseline: `31eabf8c0331cfe8e23013cef57088957cb614da`; branch:
  `agent/andee-fast-build`; scope: AndEE-specific PermawebOS files only.
- HyperBEAM remains an unmodified pinned substrate. Existing worktrees,
  processes, Docker state, and published artifacts are not modified.
- A fresh `make apk` currently builds Android ERTS and OpenSSL for both ABIs,
  Andock inputs when their private cache is absent, inference native payloads,
  a host Forge dependency/NIF tree, the platform preloaded store, the runtime
  ZIP, and finally the Gradle APK.
- Root cause: `b0452fdf` changed `apk` from the application packager into a
  dependency of the phony full-runtime target. Every no-change APK cycle then
  rebuilt both ABI payloads, WAMR, secp256k1, LMDB NIFs, the Forge store, and
  the 335 MiB runtime ZIP.
- Decision: restore the explicit build split instead of adding another cache.
  `apk` now packages and verifies a staged runtime; `android-build` serially
  rebuilds the runtime and then invokes `apk`. A missing staged runtime fails
  immediately with the full-build command. Runtime/device/native/config edits
  continue to require `android-build` and therefore retain all existing
  deterministic and application-boundary gates.
- Warm no-change baseline at the exact parent was 53.24, 55.13, and 55.18
  seconds. The repaired path, including clean final packaging and every
  composition/signature check, was 5.52, 5.42, and 5.43 seconds.
- The existing final-APK removal is not scar tissue. A negative control without
  it let AGP preserve unreferenced local ZIP data between active entries: the
  normal 406,873,335-byte artifact grew to 755,362,702 bytes. The deletion is
  retained and documented; it invalidates only final packaging, not the 39
  warm Gradle tasks. The verifier now independently rejects non-canonical APK
  ZIP layouts, and the rebuilt artifact reports zero unreferenced bytes.
- The repaired serialized `android-build` path completed successfully and
  retained the generic composition, signature, device payload, legal-notice,
  and application-negative-scan gates. Repeated `apk` packaging after that full
  build was byte-stable at SHA-256
  `8e4f25f526827f5a712a55857803cd171193c9d96fb5438eb0b31980bbe49806`.
- Re-staging the exact parent runtime and native payloads through the repaired
  `apk` target reproduced the parent APK byte-for-byte at SHA-256
  `74d5c17071afdcbe152257f1c59a3bde17d111dbaa4d362a745d91ab26eecf87`
  and 406,869,011 bytes, with zero unreferenced ZIP bytes.
- Acceptance: preserve deterministic artifact and package-boundary gates, then
  demonstrate that no-change build cycles skip unchanged expensive stages.
