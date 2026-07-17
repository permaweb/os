plugins {
    id("com.android.application")
}

android {
    namespace = "org.permaweb.andee.imageprobe"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.permaweb.andee.imageprobe"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner =
            "org.permaweb.andee.imageprobe.ImageEngineProbeInstrumentation"

        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    buildFeatures {
        aidl = true
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories.add("../../build/andock-image-engine-spike/jniLibs")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += setOf("**/libandock_image_engine_probe.so")
        }
    }
}
