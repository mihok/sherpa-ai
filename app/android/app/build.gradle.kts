import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (never committed; see .gitignore)
// with storeFile, storePassword, keyAlias and keyPassword. Without it, release
// builds fall back to the debug key so CI and `flutter run --release` work;
// such APKs can't update an install signed with the real key.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "io.github.mihok.sherpa"
    // compileSdk 37: required by receive_sharing_intent / permission_handler
    // (docs/research/09). NDK r29 matches the pinned llama.cpp build.
    compileSdk = 37
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "io.github.mihok.sherpa"
        // API 29+: on-device LLMs need ARMv8.2-class CPUs and modern memory
        // signals; newer APIs (ADPF 31, user-initiated jobs 34) are gated at runtime.
        minSdk = 29
        targetSdk = 36
        ndk {
            // Local inference ships arm64-v8a only (docs/research/05).
            abiFilters += listOf("arm64-v8a")
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // The engine's jniLibs (sherpa_inference, from
            // native/llama/build_android.sh) ship their own libc++_shared.so,
            // as do other native plugins; a library module's packaging block
            // does not reach the APK, so the app picks one. Native libraries
            // stay uncompressed and 16 KB-aligned (no useLegacyPackaging).
            pickFirsts += "**/libc++_shared.so"
            // The Flutter Gradle plugin resets `ndk.abiFilters` to
            // armeabi-v7a, arm64-v8a and x86_64, so the arm64-only filter
            // above does not reach plugin AARs. LiteRT-LM's x86_64 engine
            // (26 MB, stored uncompressed) would ship in every APK; Sherpa
            // runs on-device models on arm64 only. On an x86_64 emulator
            // sherpa_litert then reports LiteRT-LM unavailable
            // (`runtime_missing`) instead of crashing.
            excludes += "lib/x86_64/liblitertlm_jni.so"
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
