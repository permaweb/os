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
GRADLE := $(ANDROID_DIR)/gradlew
ADB := $(ANDROID_SDK_ROOT)/platform-tools/adb
EMULATOR := $(ANDROID_SDK_ROOT)/emulator/emulator
AVD_NAME ?= andee-api-36-arm64
export BUILD_DIR PERMAWEBOS_COMMON_DEVICE_ROOT ANDEE_DEVICE_OVERLAY_ROOT \
    ANDEE_DEVICE_ROOT

.PHONY: help android-env android-check android-sdk android-gradle-wrapper fetch-attestation-roots \
        apk release-keystore release-apk runtime android-build emulator-start install smoke scenarios \
        next-boot-config-test android-zone-storage-smoke zone-storage-scenario \
        verify-config-invariants erl-compile clean

help:
	@printf '%s\n' \
	    'AndEE targets:' \
	    '  make android-check              Check local Android SDK/JDK tools.' \
	    '  make android-sdk                Install/check required SDK packages.' \
	    '  make android-gradle-wrapper     Generate pinned Gradle wrapper.' \
	    '  make fetch-attestation-roots    Fetch Android Key Attestation root bundle.' \
	    '  make apk                        Build the Android APK.' \
	    '  make release-apk                Build a locally release-signed APK.' \
	    '  make runtime                    Build AndEE BEAM payload and native Android launcher.' \
	    '  make android-build              Build runtime + APK.' \
	    '  make emulator-start             Start configured Android emulator.' \
	    '  make install                    Install APK on the active device.' \
	    '  make smoke                      Boot app/service and collect smoke evidence.' \
	    '  make scenarios                  Run AndEE scenario harness.' \
	    '  make next-boot-config-test      Verify private next-boot config import path.' \
	    '  make android-zone-storage-smoke Verify Android app-private encrypted zone storage.' \
	    '  make zone-storage-scenario      Run host AndEE zone encrypted-store rejoin scenario.' \
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
	rm -f "$(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk"
	cd "$(ANDROID_DIR)" && \
	    ANDROID_HOME="$(ANDROID_HOME)" ANDROID_SDK_ROOT="$(ANDROID_SDK_ROOT)" \
	    JAVA_HOME="$(JAVA_HOME)" ./gradlew :app:assembleDebug

release-keystore:
	./scripts/android-release-keystore.sh

release-apk: runtime release-keystore
	cd "$(ANDROID_DIR)" && \
	    ANDROID_HOME="$(ANDROID_HOME)" ANDROID_SDK_ROOT="$(ANDROID_SDK_ROOT)" \
	    JAVA_HOME="$(JAVA_HOME)" ./gradlew :app:assembleRelease

runtime:
	./scripts/build-hb-android-runtime.sh

android-build: runtime apk

emulator-start:
	AVD_NAME="$(AVD_NAME)" ./scripts/start-emulator.sh

install: apk
	ANDROID_HOME="$(ANDROID_HOME)" ANDROID_SDK_ROOT="$(ANDROID_SDK_ROOT)" \
	    "$(ADB)" install -r "$(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk"

smoke: android-build
	./scripts/andee-smoke.sh

scenarios: android-build
	./scripts/andee-scenarios.sh

next-boot-config-test: apk
	./scripts/andee-next-boot-config-test.sh

android-zone-storage-smoke: android-build
	./scripts/andee-android-zone-storage-smoke.sh

zone-storage-scenario:
	./scripts/andee-zone-storage-scenario.sh

verify-config-invariants:
	./scripts/check-andee-config-invariants.py

erl-compile:
	./scripts/stage-android-devices.sh
	cd "$(ANDEE_DEVICE_ROOT)" && "$(ROOT)/scripts/verified-rebar3.sh" compile

clean:
	rm -rf "$(BUILD_DIR)" "$(ANDROID_DIR)/app/build" "$(ANDROID_DIR)/build" \
	    "$(ANDEE_DEVICE_ROOT)/_build"
