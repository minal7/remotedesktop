plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
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

fun ProviderFactory.configValue(name: String, defaultValue: String = ""): String =
    environmentVariable(name).orNull
        ?: gradleProperty(name).orNull
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

android {
    namespace = "com.threadmark.remotedesktop"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.threadmark.remotedesktop"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

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
}

dependencies {
    implementation("androidx.core:core-ktx:1.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("io.github.webrtc-sdk:android:114.5735.08.1")
}
