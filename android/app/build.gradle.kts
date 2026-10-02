import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localEnvironment = Properties()
val localEnvironmentFile = rootProject.file("../.env")
if (localEnvironmentFile.exists()) {
    localEnvironmentFile.reader().use { localEnvironment.load(it) }
}

android {
    namespace = "com.futureluck.tisranetrta"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            val storeFilePath = keystoreProperties["storeFile"] as String?
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
            }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    tasks.withType<JavaCompile> {
        options.compilerArgs.addAll(listOf("-Xlint:-deprecation", "-Xlint:-unchecked", "-Xlint:-options"))
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.futureluck.tisranetrta"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        manifestPlaceholders["googleMapsApiKey"] = localEnvironment.getProperty(
            "GOOGLE_MAPS_ANDROID_API_KEY",
            localEnvironment.getProperty("GOOGLE_MAPS_API_KEY", "")
        )
    }

    // Prevent compression of TFLite model files
    androidResources {
        noCompress += listOf("tflite", "lite")
    }

    packaging {
        jniLibs {
            doNotStrip += "**/*.so"
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.multidex:multidex:2.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}

configurations.all {
    exclude(group = "com.google.firebase", module = "firebase-iid")
}
