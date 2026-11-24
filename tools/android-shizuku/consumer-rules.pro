-keep class rikka.shizuku.server.** { *; }
-keep class moe.shizuku.starter.** { *; }
-keep class moe.shizuku.manager.adb.PairingContext { *; }
-keep class app.operit.embeddedshizuku.** { *; }

# dev.rikka.hidden:compat bridges Android system hidden APIs. These hidden classes
# (e.g. com.android.internal.app.IAppOpsService) are provided by the device at runtime
# but absent at R8 time, causing "Missing classes detected while running R8".
# Suppress the missing-class warnings; the hidden APIs are never minified away because
# they are referenced only reflectively by the hidden-api bridge.
-dontwarn com.android.internal.**
-dontwarn android.app.**
-dontwarn android.os.**

# dev.rikka.hidden / embeddedShizuku / Shizuku ADB: Android hidden framework
# classes provided by the device at runtime but absent at R8 time.
-dontwarn com.android.org.conscrypt.**
-dontwarn com.android.org.conscrypt.Conscrypt
