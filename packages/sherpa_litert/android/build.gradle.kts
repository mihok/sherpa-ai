// sherpa_litert on Android ships two on-device engines as plain Maven dependencies:
//
// 1. LiteRT-LM (com.google.ai.edge.litertlm:litertlm-android). Its AAR carries jni/arm64-v8a and jni/x86_64
//    liblitertlm_jni.so (no armeabi-v7a), already 16 KB page-aligned (LOAD align 0x4000). AGP keeps .so files
//    uncompressed and 16 KB zip-aligned in the APK (no useLegacyPackaging), so they are mmapped in place.
//    Size: ~22 MB uncompressed for arm64-v8a (the app's abiFilters drop x86_64), plus gson, kotlin-reflect and
//    kotlinx-coroutines from its POM. See the package README for measured APK impact.
// 2. Gemini Nano through the ML Kit GenAI Prompt API (com.google.mlkit:genai-prompt). No native code: inference
//    runs in AICore (com.google.android.aicore), bound over Binder; the AAR adds the AICore BIND_SERVICE
//    permission and a <queries> entry.
//
// Versions were verified on Google Maven (group-index.xml + POM last-modified) on 2026-10-19:
// litertlm-android 0.18.0 (2026-10-06; latest stable), genai-prompt 1.0.0-beta4 (2026-07-21; latest; beta,
// "not subject to any SLA or deprecation policy").
//
// Kotlin JVM tests: `./gradlew :sherpa_litert:testDebugUnitTest` from an app's android/ directory. They use fakes
// over the engine interfaces (lm/LmTypes.kt, nano/NanoTypes.kt); the real engines need a device.

group = "io.github.mihok.sherpa_litert"
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

android {
    namespace = "io.github.mihok.sherpa_litert"

    // 36 covers everything used (Build.SOC_MODEL 31, MemoryInfo-free foreground check); calls above minSdk are
    // SDK_INT-guarded. A higher compileSdk would be forced on every app (AAR metadata check).
    compileSdk = 36

    defaultConfig {
        // PLAN §4. LiteRT-LM needs 24, ML Kit GenAI 26, the NPU backend 31 (runtime-gated by the model file).
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    testOptions {
        unitTests {
            // android.util.Log in the generated Pigeon code: stubs return defaults.
            isReturnDefaultValues = true
            all {
                it.testLogging {
                    events("passed", "skipped", "failed")
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
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.0")
    implementation("com.google.mlkit:genai-prompt:1.0.0-beta4")
    // Used directly (Pigeon's suspend host API, Nano jobs). Same version LiteRT-LM 0.18.0's POM pulls in.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    testImplementation("junit:junit:4.13.2")
}
