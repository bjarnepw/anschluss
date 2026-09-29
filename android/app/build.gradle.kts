import java.util.Properties

// Release signing: android/key.properties locally (not in git), or environment variables on CI.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signing(prop: String, env: String): String? = keyProps.getProperty(prop) ?: System.getenv(env)
val releaseStore = signing("storeFile", "ANDROID_KEYSTORE_PATH")

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "de.bjarnepw.anschluss"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "de.bjarnepw.anschluss"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = signing("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signing("keyAlias", "ANDROID_KEY_ALIAS") ?: "anschluss"
                keyPassword = signing("keyPassword", "ANDROID_KEY_PASSWORD") ?: storePassword
            }
        }
    }

    buildFeatures {
        resValues = true
    }

    buildTypes {
        // Debug builds install next to the release app ("Anschluss Dev"), so testing never touches its data.
        debug {
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Anschluss Dev")
        }
        // Profile = release speed, but also installed next to the real app.
        maybeCreate("profile").apply {
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Anschluss Dev")
        }
        release {
            resValue("string", "app_name", "Anschluss")
            // Own key when available (same key = updates install over each other); debug key otherwise,
            // so the project still builds for anyone without the key.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
