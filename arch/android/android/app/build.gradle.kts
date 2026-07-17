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
