allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Plugins that pin an older compileSdk (notification_listener_service: 34)
// would need that platform in the Android SDK, and the SDK lives in the
// read-only Nix store with only what devenv.nix lists. Build every library
// against the app's own SDK (36) instead. Registered before :app is evaluated
// below, so the hook is in place for every plugin.
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.gradle.LibraryExtension>()?.let {
            // raise only: a plugin that wants newer must not be held back
            if ((it.compileSdk ?: 0) < 36) it.compileSdk = 36
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
