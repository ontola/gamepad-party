import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Use the same switch as Dart, so installer permissions and UI cannot drift.
val playStore = (project.findProperty("dart-defines") as? String)
    ?.split(",")
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    ?.contains("GAMENIGHT_PLAY_STORE=true") == true

android {
    namespace = "io.ontola.gamenight"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures { buildConfig = true }
    if (playStore) {
        sourceSets.getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.ontola.gamenight"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "PLAY_STORE", playStore.toString())
        // The native host's library, when CI (or a local build) put it in
        // jniLibs; without it "Host on this phone" uses the browser host.
        buildConfigField("boolean", "NATIVE_HOST", file("src/main/jniLibs/arm64-v8a/libsplitscreen_host.so").exists().toString())
    }

    // The native host brings its own libc++_shared.so; another library may too.
    packaging { jniLibs { pickFirsts += "**/libc++_shared.so" } }

    // CI signs with one fixed key (a GitHub secret), so a new APK can update
    // the installed app and Android can verify the app's links on
    // gamenight.ontola.io (the site's assetlinks.json holds the key's
    // fingerprint). Without the key, e.g. a local build, the debug key is used.
    val keystoreFile = System.getenv("GAMENIGHT_KEYSTORE_FILE")
    if (keystoreFile != null) {
        signingConfigs {
            create("gamenight") {
                storeFile = file(keystoreFile)
                storePassword = System.getenv("GAMENIGHT_KEYSTORE_PASSWORD")
                keyAlias = "gamenight"
                keyPassword = System.getenv("GAMENIGHT_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (keystoreFile != null) "gamenight" else "debug")
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
    // Host mode runs the browser host in Chrome as a Trusted Web Activity
    // (HostLauncher.kt): Chrome's own process, so a long engine frame can't
    // make Android call the app unresponsive, as the in-app WebView did.
    implementation("com.google.androidbrowserhelper:androidbrowserhelper:2.5.0")
}
