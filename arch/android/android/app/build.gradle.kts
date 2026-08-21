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
        buildConfigField("String", "LLAMA_CPP_VERSION", "\"b10502\"")
        buildConfigField(
            "String",
            "LLAMA_CPP_COMMIT",
            "\"0adcc3bb571011bff8b91335d0728a82845c421b\"",
        )
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

val liteRtNoticesDirectory = layout.buildDirectory.dir("generated/litert-notices")
android.sourceSets.getByName("main").assets.directories.add(
    liteRtNoticesDirectory.get().asFile.absolutePath,
)
val llamaCppNoticesDirectory = rootProject.projectDir.parentFile
    .resolve("build/llama-cpp-runtime/notices")
android.sourceSets.getByName("main").assets.directories.add(
    llamaCppNoticesDirectory.absolutePath,
)

val stageLiteRtNotices = tasks.register<Copy>("stageLiteRtNotices") {
    from(
        provider {
            val artifact = configurations.getByName("debugRuntimeClasspath")
                .files
                .single { it.name == "litertlm-android-0.16.1.aar" }
            zipTree(artifact)
        },
    )
    include("LICENSE", "THIRD_PARTY_NOTICE.txt")
    into(liteRtNoticesDirectory.map { it.dir("litertlm-android-0.16.1") })
}

dependencies {
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.16.1")
    testImplementation("junit:junit:4.13.2")
}

val verifyGeneratedRuntime = tasks.register("verifyGeneratedRuntime") {
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
        check(file("$nativeRoot/arm64-v8a/libLiteRtDispatch_GoogleTensor.so").isFile) {
            "Missing pinned Google Tensor LiteRT dispatch runtime"
        }
        for (
            name in listOf(
                "libandee_llama_server.so",
                "libllama-server-impl.so",
                "libllama-common.so",
                "libmtmd.so",
                "libllama.so",
                "libggml.so",
                "libggml-base.so",
                "libggml-cpu-android_armv8.0_1.so",
                "libggml-cpu-android_armv8.2_1.so",
                "libggml-cpu-android_armv8.2_2.so",
                "libggml-cpu-android_armv8.6_1.so",
                "libggml-cpu-android_armv9.0_1.so",
                "libggml-cpu-android_armv9.2_1.so",
                "libggml-cpu-android_armv9.2_2.so",
            )
        ) {
            check(file("$nativeRoot/arm64-v8a/$name").isFile) {
                "Missing pinned llama.cpp Android runtime: $name"
            }
        }
        check(file("$llamaCppNoticesDirectory/llama-cpp-b10502/LICENSE").isFile) {
            "Missing pinned llama.cpp legal notice"
        }
    }
}

tasks.matching { task ->
    task.name == "mergeDebugAssets" || task.name == "mergeReleaseAssets"
}.configureEach {
    dependsOn(stageLiteRtNotices)
}

tasks.matching { task ->
    task.name == "packageDebug" || task.name == "packageRelease"
}.configureEach {
    dependsOn(verifyGeneratedRuntime)
}
