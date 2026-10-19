group = "io.github.mihok.sherpa_webview"
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

// KGP is not applied here: the Flutter Gradle plugin applies Kotlin to
// plugins itself (same as sherpa_platform, R09 §0.3).
plugins {
    id("com.android.library")
}

android {
    namespace = "io.github.mihok.sherpa_webview"

    compileSdk = 37

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

    defaultConfig {
        // PLAN §4: minSdk 29. Every androidx.webkit call is feature-gated
        // with WebViewFeature.isFeatureSupported (the WebView APK decides).
        minSdk = 29
    }

    testOptions {
        unitTests {
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
    // addWebMessageListener, profiles, document-start scripts, settings
    // compat (R03 §0: latest stable 1.17.1).
    implementation("androidx.webkit:webkit:1.17.1")
    // Pure-JVM tests for ShellPolicy.kt (no Robolectric).
    testImplementation("junit:junit:4.13.2")
}
