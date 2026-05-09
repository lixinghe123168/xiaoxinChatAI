allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // 启用构建缓存加速编译
    configurations.all {
        resolutionStrategy.cacheDynamicVersionsFor(10, "minutes")
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

    // 强制统一所有子项目的 Java 和 Kotlin 编译目标
    afterEvaluate {
        // 如果子项目里有 android 配置，统一 Java 版本
        if (project.hasProperty("android")) {
            extensions.findByName("android")?.let { androidExt ->
                (androidExt as com.android.build.gradle.BaseExtension).compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
        // 统一所有 Kotlin 编译任务的 JVM 目标
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}