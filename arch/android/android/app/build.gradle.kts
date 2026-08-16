plugins {
    id("com.android.application")
}

android {
    namespace = "org.permaweb.andee"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.permaweb.andee"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("int", "MIN_OS_PATCH_LEVEL", "202605")
        buildConfigField("int", "MIN_VENDOR_PATCH_LEVEL", "20260501")
        buildConfigField("int", "MIN_BOOT_PATCH_LEVEL", "20260501")
    }

    buildFeatures {
        aidl = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += setOf("**/libandee_*.so")
        }
    }

    signingConfigs {
        create("releaseLocal") {
            storeFile = file("${rootProject.projectDir}/andee-release.local.keystore")
            storePassword = "andee-local"
            keyAlias = "andee-local"
            keyPassword = "andee-local"
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ""
            isDebuggable = true
        }
        release {
            isDebuggable = false
            isMinifyEnabled = true
            signingConfig = signingConfigs.getByName("releaseLocal")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

tasks.named("preBuild").configure {
    doFirst {
        val runtime = file("src/main/assets/andee-runtime.zip")
        val nativeRoot = file("src/main/jniLibs")
        check(runtime.isFile) {
            "Missing generated AndEE runtime; build APKs through arch/android/Makefile"
        }
        for (abi in listOf("arm64-v8a", "x86_64")) {
            check(file("$nativeRoot/$abi/libandee_hyperbeam.so").isFile) {
                "Missing generated $abi AndEE native runtime; build through arch/android/Makefile"
            }
        }
    }
}
