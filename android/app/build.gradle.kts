import com.github.triplet.gradle.androidpublisher.ReleaseStatus
import java.io.File

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.github.triplet.play") version "3.13.0"
}

fun loadDotenv(file: File): Map<String, String> {
    if (!file.isFile) return emptyMap()
    return file.readLines()
        .asSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }
        .map { line -> if (line.startsWith("export ")) line.removePrefix("export ").trim() else line }
        .mapNotNull { line ->
            val separator = line.indexOf('=')
            if (separator <= 0) return@mapNotNull null
            val key = line.substring(0, separator).trim()
            val rawValue = line.substring(separator + 1).trim()
            val value = rawValue
                .removeSurrounding("\"")
                .removeSurrounding("'")
            key to value
        }
        .toMap()
}

val dotenv = loadDotenv(rootProject.file(".env"))
val signingProperties = loadDotenv(rootProject.file("key.properties"))

fun ProviderFactory.configValue(name: String, defaultValue: String = ""): String =
    environmentVariable(name).orNull
        ?: gradleProperty(name).orNull
        ?: dotenv[name]
        ?: defaultValue

fun ProviderFactory.signingValue(name: String, defaultValue: String = ""): String =
    environmentVariable(name).orNull
        ?: gradleProperty(name).orNull
        ?: signingProperties[name]
        ?: dotenv[name]
        ?: defaultValue

fun ProviderFactory.authCallbackUrl(): String {
    configValue("REMOTE_DESKTOP_CLOUDKIT_AUTH_CALLBACK_URL").takeIf { it.isNotBlank() }?.let {
        return it
    }
    val bind = configValue("REMOTE_DESKTOP_AUTH_CALLBACK_BIND", "127.0.0.1:48172")
    val path = configValue("REMOTE_DESKTOP_AUTH_CALLBACK_PATH", "/icloud-auth-callback")
        .let { if (it.startsWith('/')) it else "/$it" }
    return "https://$bind$path"
}

fun String.asBuildConfigString(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val uploadStoreFile = providers.signingValue("REMOTE_DESKTOP_UPLOAD_STORE_FILE")
val uploadStorePassword = providers.signingValue("REMOTE_DESKTOP_UPLOAD_STORE_PASSWORD")
val uploadKeyAlias = providers.signingValue("REMOTE_DESKTOP_UPLOAD_KEY_ALIAS")
val uploadKeyPassword = providers.signingValue("REMOTE_DESKTOP_UPLOAD_KEY_PASSWORD")
val playServiceAccountFile = providers.signingValue(
    "REMOTE_DESKTOP_PLAY_SERVICE_ACCOUNT_FILE",
    "play-publisher-service-account.json",
)
val playTrack = providers.signingValue("REMOTE_DESKTOP_PLAY_TRACK", "internal")
val playReleaseStatus = when (providers.signingValue("REMOTE_DESKTOP_PLAY_RELEASE_STATUS", "completed").lowercase()) {
    "draft" -> ReleaseStatus.DRAFT
    "halted" -> ReleaseStatus.HALTED
    "inprogress", "in_progress", "in-progress" -> ReleaseStatus.IN_PROGRESS
    else -> ReleaseStatus.COMPLETED
}
val hasUploadSigningConfig = listOf(
    uploadStoreFile,
    uploadStorePassword,
    uploadKeyAlias,
    uploadKeyPassword
).all { it.isNotBlank() }

android {
    namespace = "com.threadmark.remotedesktop"
    compileSdk = 35

    signingConfigs {
        if (hasUploadSigningConfig) {
            create("release") {
                val storePath = File(uploadStoreFile)
                storeFile = if (storePath.isAbsolute) storePath else rootProject.file(uploadStoreFile)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    defaultConfig {
        applicationId = "com.threadmark.remotedesktopclient"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "0.1.1"

        buildConfigField(
            "String",
            "CLOUDKIT_CONTAINER",
            providers.configValue(
                "REMOTE_DESKTOP_CLOUDKIT_CONTAINER",
                "iCloud.com.threadmark.remotedesktop"
            ).asBuildConfigString()
        )
        buildConfigField(
            "String",
            "CLOUDKIT_ENV",
            providers.configValue("REMOTE_DESKTOP_CLOUDKIT_ENV", "development")
                .lowercase()
                .asBuildConfigString()
        )
        buildConfigField(
            "String",
            "CLOUDKIT_API_TOKEN",
            providers.configValue("REMOTE_DESKTOP_CLOUDKIT_API_TOKEN")
                .asBuildConfigString()
        )
        buildConfigField(
            "String",
            "CLOUDKIT_AUTH_CALLBACK_URL",
            providers.authCallbackUrl().asBuildConfigString()
        )
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            if (hasUploadSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("io.github.webrtc-sdk:android:144.7559.09")
}

play {
    serviceAccountCredentials.set(rootProject.file(playServiceAccountFile))
    track.set(playTrack)
    releaseStatus.set(playReleaseStatus)
    defaultToAppBundles.set(true)
}
