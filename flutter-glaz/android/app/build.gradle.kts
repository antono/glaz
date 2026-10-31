import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.glaz.glaz"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.glaz.glaz"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ML Kit's speech recognition (Speech.kt) needs 26
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Phones are ARM: no x86 libraries, Flutter's or the plugins' (offline
    // translation, OCR), each tens of MB. Debug builds and `flutter run`
    // stay as they are, on a phone; not on an x86 emulator. Excluded here,
    // as abiFilters are not: Flutter's plugin adds its target platforms
    // (x64 among them) to those.
    packaging {
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
        }
    }

    // The canonical key, android/glaz.jks: from `git secret reveal`, or
    // from the secrets in CI. Every build signed with it installs over any
    // other. Without it, the machine's own debug key.
    val keyFile = rootProject.file("key.properties")
    val glaz =
        if (keyFile.exists()) {
            val key = Properties().apply { keyFile.inputStream().use { load(it) } }
            signingConfigs.create("glaz") {
                storeFile = rootProject.file(key.getProperty("storeFile"))
                storePassword = key.getProperty("storePassword")
                keyAlias = key.getProperty("keyAlias")
                keyPassword = key.getProperty("keyPassword")
            }
        } else {
            signingConfigs.getByName("debug")
        }

    buildTypes {
        debug {
            signingConfig = glaz
        }
        release {
            signingConfig = glaz
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
    // speech to text on the phone, Speech.kt
    implementation("com.google.mlkit:genai-speech-recognition:1.0.0-alpha1")
    // text on a photo, Translate (lib/services/translate.dart): the plugin
    // brings Latin only; these read the other scripts it knows
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}
