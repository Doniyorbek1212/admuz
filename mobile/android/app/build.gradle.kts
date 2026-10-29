import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Push notifications: drop a Firebase config at android/app/google-services.json to enable FCM.
// Without it the app builds and runs normally and push stays off (see lib/core/push.dart).
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Release signing: create android/key.properties (storeFile, storePassword, keyAlias, keyPassword).
// Without it a release build fails, so a debug-signed APK can't be shipped by mistake. For a local test
// build only: flutter build apk --release --android-project-arg allowDebugSigning=true
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "uz.sado.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Needed by flutter_local_notifications.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "uz.uzaro.app"
        // TDLib and the audio recorder need API 24+.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABIs: Flutter's Gradle plugin limits non-split builds to armeabi-v7a/arm64-v8a/x86_64, the same
        // set tool/build_tdlib_android.sh builds libtdjson.so for; --split-per-abi configures splits itself.
    }

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
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
            signingConfig = signingConfigs.findByName("release")
                ?: if (project.hasProperty("allowDebugSigning")) signingConfigs.getByName("debug") else null
        }
    }

    packaging {
        jniLibs {
            // Keep libtdjson.so uncompressed and page-aligned so it can be mapped directly.
            useLegacyPackaging = false
            // Drop ABIs without a built libtdjson.so: plugins still ship libs for them, so Play would
            // serve those devices a split that crashes on start.
            listOf("armeabi-v7a", "arm64-v8a", "x86_64")
                .filterNot { file("src/main/jniLibs/$it/libtdjson.so").exists() }
                .forEach { excludes += "lib/$it/**" }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // Square crop of round video messages (VideoNoteTranscoder); same media3 line as video_player's ExoPlayer.
    implementation("androidx.media3:media3-transformer:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    implementation("androidx.media3:media3-common:1.9.2")
}

flutter {
    source = "../.."
}

// Fail before compiling, not after: a release artifact must carry the release key.
gradle.taskGraph.whenReady {
    val releaseArtifact = allTasks.any { task ->
        task.project == project && task.name.endsWith("Release") &&
            (task.name.startsWith("assemble") || task.name.startsWith("bundle") || task.name.startsWith("package"))
    }
    if (releaseArtifact && android.signingConfigs.findByName("release") == null && !project.hasProperty("allowDebugSigning")) {
        throw GradleException(
            "Release signing key missing: add android/key.properties (see the top of this file). " +
                "Local test build only: --android-project-arg allowDebugSigning=true",
        )
    }
}
