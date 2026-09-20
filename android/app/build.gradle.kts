plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.opensourceglasses.even_g2_r1_poc"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.opensourceglasses.even_g2_r1_poc"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The vendored arm64 Sherpa-ONNX runtime is compiled for API 27 so its
        // NNAPI registration code is present. NNAPI is offered only on API 29+
        // by the Dart capability gate; API 27-28 continue to use CPU.
        minSdk = 27
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 runs in release builds. proguard-rules.pro keeps the
            // LiteRT-LM classes its own JNI layer resolves by name; without it
            // only debug builds can correct a transcript.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Match reactive_ble_mobile's RxJava runtime so the application can
    // install a narrowly scoped undeliverable-error handler.
    implementation("io.reactivex.rxjava2:rxjava:2.2.17")
    // Pinned so model/runtime qualification remains reproducible. Gemma runs
    // in a dedicated Android process and requests the GPU backend explicitly.
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.14.0")
}
