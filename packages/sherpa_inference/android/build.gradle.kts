// sherpa_inference ships no Java/Kotlin and compiles no native code: it only
// packages the prebuilt engine from native/llama/build_android.sh
// (libsherpa_engine.so, libllama.so, libggml*.so incl. the seven
// libggml-cpu-android_* variants, libc++_shared.so) as jniLibs, so they land
// uncompressed and 16 KB-aligned in the APK. The Dart side opens
// libsherpa_engine.so by bare name; the engine dlopens the best CPU variant by
// bare name too, which bionic resolves inside the APK (R05 §4.3, PLAN
// finding 10) — no extractNativeLibs / useLegacyPackaging needed.
//
// The prebuilt directory is a build output and never committed. Override it
// with -Psherpa.engineJniLibs=<dir> or SHERPA_ENGINE_JNILIBS. When it does not
// exist the build still succeeds (with a warning) and the app reports
// "engine unavailable" at runtime.

group = "io.github.mihok.sherpa_inference"
version = "1.0-SNAPSHOT"

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

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

    // No Java/Kotlin here, so no API level is needed beyond the default
    // template's; a higher compileSdk would force it on every app (AAR
    // metadata check). minSdk follows PLAN §4.
    compileSdk = 36

    defaultConfig {
        minSdk = 29
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            // A missing directory is simply an empty source set.
            jniLibs.srcDir(engineJniLibs)
        }
    }

    packaging {
        jniLibs {
            // Other plugins may also ship the NDK's libc++_shared.so. This
            // only affects this module's own outputs; the app must repeat it
            // (see the package README, "Integrating").
            pickFirsts += "**/libc++_shared.so"
        }
    }
}
