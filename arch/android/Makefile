# AndEE operator/developer surface.

ROOT := $(abspath .)
PERMAWEBOS_ROOT := $(abspath ../..)
BUILD_DIR ?= $(ROOT)/build
ANDROID_DIR := $(ROOT)/android
PERMAWEBOS_COMMON_DEVICE_ROOT ?= $(PERMAWEBOS_ROOT)/devices/common
ANDEE_DEVICE_OVERLAY_ROOT ?= $(PERMAWEBOS_ROOT)/devices/android
ANDEE_DEVICE_ROOT ?= $(BUILD_DIR)/android-devices
ANDROID_SDK_ROOT ?= /opt/homebrew/share/android-commandlinetools
ANDROID_HOME ?= $(ANDROID_SDK_ROOT)
JAVA_HOME ?= /opt/homebrew/opt/openjdk@17
ANDROID_BUILD_TOOLS_VERSION ?= 36.0.0
GRADLE := $(ANDROID_DIR)/gradlew
ADB := $(ANDROID_SDK_ROOT)/platform-tools/adb
EMULATOR := $(ANDROID_SDK_ROOT)/emulator/emulator
AAPT2 := $(ANDROID_SDK_ROOT)/build-tools/$(ANDROID_BUILD_TOOLS_VERSION)/aapt2
APKSIGNER := $(ANDROID_SDK_ROOT)/build-tools/$(ANDROID_BUILD_TOOLS_VERSION)/apksigner
DEBUG_APK := $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk
EMULATOR_INFERENCE_APK := $(BUILD_DIR)/app-debug-emulator.apk
RUNTIME_ZIP := $(ANDROID_DIR)/app/src/main/assets/andee-runtime.zip
AVD_NAME ?= andee-api-36-arm64
export BUILD_DIR PERMAWEBOS_COMMON_DEVICE_ROOT ANDEE_DEVICE_OVERLAY_ROOT \
    ANDEE_DEVICE_ROOT

.PHONY: help android-env android-check android-sdk android-gradle-wrapper fetch-attestation-roots \
        apk verify-apk release-keystore release-apk runtime android-build emulator-start install smoke \
        zone-storage-scenario inference-emulator-apk inference-emulator-smoke \
        verify-config-invariants erl-compile andock-template \
        andock-template-reproducibility preloaded-store-reproducibility clean

help:
	@printf '%s\n' \
	    'AndEE targets:' \
	    '  make android-check              Check local Android SDK/JDK tools.' \
	    '  make android-sdk                Install/check required SDK packages.' \
	    '  make android-gradle-wrapper     Generate pinned Gradle wrapper.' \
	    '  make fetch-attestation-roots    Fetch Android Key Attestation root bundle.' \
	    '  make apk                        Package the staged runtime into the Android APK.' \
	    '  make verify-apk                 Verify APK identity, signature, and generic composition.' \
	    '  make release-apk                Build a locally release-signed APK.' \
	    '  make runtime                    Rebuild AndEE BEAM and native runtime payloads.' \
	    '  make android-build              Rebuild the runtime, then package the APK.' \
	    '  make emulator-start             Start configured Android emulator.' \
	    '  make install                    Install APK on explicit ADB_SERIAL.' \
	    '  make smoke                      Boot app/service and collect smoke evidence.' \
	    '  make zone-storage-scenario      Run host AndEE zone encrypted-store rejoin scenario.' \
	    '  make inference-emulator-apk     Build the verified Apple-ARM64 emulator LiteRT-LM override.' \
	    '  make inference-emulator-smoke   Prove network-materialized inference on an emulator CPU.' \
	    '  make andock-template            Build pinned ARM64 Andock ext4 and sparse images.' \
	    '  make andock-template-reproducibility  Rebuild and compare the template twice.' \
	    '  make preloaded-store-reproducibility  Rebuild and compare the preload twice.' \
	    '  make verify-config-invariants   Check enforced HB config invariants.' \
	    '  make erl-compile                Compile AndEE device package.'

android-check:
	./scripts/android-check.sh

android-sdk:
	./scripts/android-sdk.sh

android-gradle-wrapper:
	./scripts/android-gradle-wrapper.sh

fetch-attestation-roots:
	./scripts/fetch-android-attestation-roots.py

apk:
	@test -f "$(RUNTIME_ZIP)" || { \
	    echo 'AndEE runtime is not staged; run `make android-build`.' >&2; \
	    exit 1; \
	}
	# AGP can retain unreachable ZIP data when updating an existing APK.
	# Remove only the final package; compiled tasks remain warm.
	rm -f "$(DEBUG_APK)"
	cd "$(ANDROID_DIR)" && \
	    ANDROID_HOME="$(ANDROID_HOME)" ANDROID_SDK_ROOT="$(ANDROID_SDK_ROOT)" \
	    JAVA_HOME="$(JAVA_HOME)" ./gradlew :app:assembleDebug
	$(MAKE) verify-apk

verify-apk:
	JAVA_HOME="$(JAVA_HOME)" ./scripts/verify-generic-andee-artifact.py \
	    --apk "$(DEBUG_APK)" \
	    --expected-runtime-sha256 "$$(shasum -a 256 "$(RUNTIME_ZIP)" | awk '{print $$1}')" \
	    --aapt2 "$(AAPT2)" \
	    --apksigner "$(APKSIGNER)" \
	    --evidence "$(BUILD_DIR)/andee-apk-composition.json"

release-keystore:
	./scripts/android-release-keystore.sh

release-apk: runtime release-keystore
	cd "$(ANDROID_DIR)" && \
	    ANDROID_HOME="$(ANDROID_HOME)" ANDROID_SDK_ROOT="$(ANDROID_SDK_ROOT)" \
	    JAVA_HOME="$(JAVA_HOME)" ./gradlew :app:assembleRelease

runtime:
	./scripts/build-hb-android-runtime.sh

android-build: runtime
	$(MAKE) apk

emulator-start:
	AVD_NAME="$(AVD_NAME)" ./scripts/start-emulator.sh

install: apk
	@test -n "$(ADB_SERIAL)" || { echo 'set ADB_SERIAL explicitly' >&2; exit 1; }
	ANDROID_HOME="$(ANDROID_HOME)" ANDROID_SDK_ROOT="$(ANDROID_SDK_ROOT)" \
	    "$(ADB)" -s "$(ADB_SERIAL)" install -r \
	        "$(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk"

smoke: android-build
	./scripts/andee-smoke.sh

zone-storage-scenario:
	./scripts/andee-zone-storage-scenario.sh

inference-emulator-apk: apk
	./scripts/build-andee-emulator-apk.sh

inference-emulator-smoke: inference-emulator-apk
	APK="$(EMULATOR_INFERENCE_APK)" ./scripts/andee-inference-emulator-smoke.sh

verify-config-invariants:
	./scripts/check-andee-config-invariants.py
	./scripts/check-no-andee-debug-writes.py

erl-compile:
	./scripts/stage-android-devices.sh
	cd "$(ANDEE_DEVICE_ROOT)" && "$(ROOT)/scripts/verified-rebar3.sh" compile

andock-template:
	./scripts/build-andock-template.sh

andock-template-reproducibility:
	./scripts/test-andock-template-reproducibility.sh

preloaded-store-reproducibility:
	./scripts/test-andee-preloaded-store-reproducibility.sh

clean:
	rm -rf "$(BUILD_DIR)" "$(ANDROID_DIR)/app/build" "$(ANDROID_DIR)/build" \
	    "$(ANDEE_DEVICE_ROOT)/_build" "$(ANDROID_DIR)/app/src/main/jniLibs"
	rm -f "$(ANDROID_DIR)/app/src/main/assets/andee-runtime.zip"
