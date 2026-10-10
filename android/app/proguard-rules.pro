# Flutter Rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.provider.** { *; }
-keep class io.flutter.plugins.** { *; }

# Libsignal JNI / Android Rules
-keep class org.signal.** { *; }
-keepclassmembers class org.signal.** { *; }
-dontwarn org.signal.**

# Android Keystore & Cryptography
-keep class java.security.** { *; }
-keep class javax.crypto.** { *; }

# Gson / Serialization rules
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-dontwarn javax.annotation.**

# Supabase & Realtime / Kotlin Coroutines
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**
