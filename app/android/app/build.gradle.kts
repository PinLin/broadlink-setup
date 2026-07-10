plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "me.pinlin.broadlink_setup"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        // Needed for BuildConfig.VERSION_CODE, used by FreeDroidWarn's upgrade check.
        buildConfig = true
    }

    defaultConfig {
        applicationId = "me.pinlin.broadlink_setup"
        // WifiNetworkSpecifier requires Android 10+ (API 29).
        minSdk = 29
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: real signing config before public release.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Shows a one-time dialog on app upgrade pointing users to FOSS alternatives.
    // Pinned to the latest tagged release (V1.13); JitPack does not host a floating version.
    implementation("com.github.woheller69:FreeDroidWarn:V1.13")
}
