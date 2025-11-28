plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.avishkar.quantkey"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // Unique Application ID for Play Store
        applicationId = "com.avishkar.quantkey"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Note: For Play Store release, you need to create a signing config
            // See: https://developer.android.com/studio/publish/app-signing
            // For now, using debug keys. Replace with your release signing config before publishing.
            signingConfig = signingConfigs.getByName("debug")
            // Temporarily disabled minification to fix R8 errors with Play Core
            // Re-enable after adding proper ProGuard rules if needed
            isMinifyEnabled = false
            // Resource shrinking requires minification to be enabled
            isShrinkResources = false
            // proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}
