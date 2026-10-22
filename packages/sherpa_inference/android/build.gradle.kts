// sherpa_inference on Android ships two things:
//
// 1. The prebuilt engine from native/llama/build_android.sh (libsherpa_engine.so, libllama.so, libggml*.so
//    incl. the seven libggml-cpu-android_* variants, libc++_shared.so) as jniLibs, so they land uncompressed
//    and 16 KB-aligned in the APK. The engine dlopens the best CPU variant by bare name, which bionic
//    resolves inside the APK (R05 §4.3, PLAN finding 10) — no extractNativeLibs / useLegacyPackaging needed.
//    The prebuilt directory is a build output and never committed. Override it with
//    -Psherpa.engineJniLibs=<dir> or SHERPA_ENGINE_JNILIBS. When it does not exist the build still succeeds
//    (with a warning) and the app reports "engine unavailable" at runtime.
//
// 2. The out-of-process host: SherpaInferencePlugin (main process) binds InferenceService in the private
//    `:inference` process (src/main/AndroidManifest.xml) over AIDL (src/main/aidl), and the service drives
//    the engine through a small JNI shim (src/main/cpp, plain C, built here with CMake). The shim compiles
//    against native/engine/include/sherpa_engine.h only and dlopens libsherpa_engine.so at runtime, so (1)
//    stays optional. The Dart FFI host (FfiEngineHost) opens the same libsherpa_engine.so in-process.
//
// Kotlin JVM tests: `./gradlew :sherpa_inference:testDebugUnitTest` from an app's android/ directory. The
// real-engine tests need the host shim (tool/build_host_jni.sh) and skip without it.

group = "io.github.mihok.sherpa_inference"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// KGP is not applied here: the Flutter Gradle plugin applies Kotlin to plugins itself (see
// sherpa_platform/android/build.gradle.kts, R09 §0.3).
plugins {
    id("com.android.library")
}

val engineJniLibs: File = run {
    val override = (findProperty("sherpa.engineJniLibs") as String?) ?: System.getenv("SHERPA_ENGINE_JNILIBS")
    if (override != null && override.isNotBlank()) file(override)
    else file("../../../native/llama/out/android/jniLibs")
}

if (!File(engineJniLibs, "arm64-v8a/libsherpa_engine.so").isFile) {
    logger.warn(
        "sherpa_inference: no prebuilt engine at ${engineJniLibs.path}; on-device inference will be " +
            "unavailable in this build. Run native/llama/build_android.sh (or set sherpa.engineJniLibs)."
    )
}

android {
    namespace = "io.github.mihok.sherpa_inference"

    // API 36 covers everything used (ApplicationExitInfo 30, tombstone traces 31, REASON_* up to 34,
    // BIND_NOT_PERCEPTIBLE 29); calls above minSdk are SDK_INT-guarded. A higher compileSdk would be forced
    // on every app (AAR metadata check). minSdk follows PLAN §4.
    compileSdk = 36
    // Same NDK as the app and native/llama/build_android.sh.
    ndkVersion = "29.0.14206865"

    defaultConfig {
        minSdk = 29
        // JNI lookups by name (see the file) survive the app's R8 pass.
        consumerProguardFiles("consumer-rules.pro")
        ndk {
            // The engine is arm64-v8a only (native/llama/build_android.sh). On other ABIs (x86_64
            // emulators) the shim is absent, InferenceService reports "engine unavailable" — the same
            // outcome a shim without an engine would give.
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                // Plain C: no STL, so this module adds no second libc++_shared.so next to the engine's.
                arguments += listOf("-DANDROID_STL=none")
            }
        }
    }

    buildFeatures {
        aidl = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            // A missing directory is simply an empty source set.
            jniLibs.srcDir(engineJniLibs)
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    packaging {
        jniLibs {
            // Other plugins may also ship the NDK's libc++_shared.so. This only affects this module's own
            // outputs; the app must repeat it (see the package README, "Integrating").
            pickFirsts += "**/libc++_shared.so"
        }
    }

    testOptions {
        unitTests {
            // android.util.Log in the generated Pigeon code and Blob-free paths: stubs return defaults.
            isReturnDefaultValues = true
            all {
                it.testLogging {
                    events("passed", "skipped", "failed")
                    showStandardStreams = true
                }
                val hostJni = (findProperty("sherpa.hostJni") as String?) ?: System.getenv("SHERPA_JNI_LIB")
                    ?: file("../build/host-jni/libsherpa_inference_jni.so").absolutePath
                it.systemProperty("sherpa.hostJni", hostJni)
                listOf("SHERPA_ENGINE_LIB", "SHERPA_TEST_MODEL", "SHERPA_TEST_THREADS").forEach { name ->
                    System.getenv(name)?.let { v -> it.environment(name, v) }
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Plain JVM tests (no Robolectric): the dispatcher, pump, codec, exit decoding, and the JNI shim against
    // the host-built engine.
    testImplementation("junit:junit:4.13.2")
}
