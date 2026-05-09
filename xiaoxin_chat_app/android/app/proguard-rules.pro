# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.

# Flutter specific rules
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep custom classes
-keep class com.xiaoxinchat.** { *; }
