group = "io.github.mihok.sherpa_platform"
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
// plugins itself, and plugins that apply KGP trigger the "future versions of
// Flutter will fail" warning (R09 §0.3).
plugins {
    id("com.android.library")
}

android {
    namespace = "io.github.mihok.sherpa_platform"

    // 37 for MemoryInfo.freeMem and the Android 17 surface; every call above
    // minSdk is guarded by an SDK_INT check.
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
        // PLAN §4: minSdk 29 (thermal status listener, startForeground with a type).
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
    // Pure-JVM tests for the parsers in NativeParsers.kt (no Robolectric).
    testImplementation("junit:junit:4.13.2")
}
