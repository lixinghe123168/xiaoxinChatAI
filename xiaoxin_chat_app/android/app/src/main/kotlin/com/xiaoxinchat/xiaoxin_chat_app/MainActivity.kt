package com.xiaoxinchat.xiaoxin_chat_app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.xiaoxinchat.xiaoxin_chat_app/restart"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "restartApp" -> {
                    restartApp()
                    result.success(true)
                }
                "setAppDisplay" -> {
                    val label = call.argument<String>("label") ?: ""
                    val iconPath = call.argument<String>("iconPath")
                    setAppDisplay(label, iconPath)
                    result.success(true)
                }
                "createHomeShortcut" -> {
                    val label = call.argument<String>("label") ?: ""
                    val iconPath = call.argument<String>("iconPath")
                    val success = createHomeShortcut(label, iconPath)
                    result.success(success)
                }
                "isShortcutSupported" -> {
                    val supported = isShortcutSupported()
                    result.success(supported)
                }
                else -> result.notImplemented()
            }
        }
        applySavedAppDisplay()
    }

    private fun restartApp() {
        Log.d("MainActivity", "restartApp called")
        try {
            val intent = Intent(this, MainActivity::class.java)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            startActivity(intent)
            finish()
        } catch (e: Exception) {
            Log.e("MainActivity", "restartApp failed: $e")
        }
    }

    private fun setAppDisplay(label: String, iconPath: String?) {
        Log.d("MainActivity", "setAppDisplay: label=$label iconPath=$iconPath")
        if (label.isEmpty() && iconPath == null) {
            Log.w("MainActivity", "setAppDisplay: both label and iconPath are empty, skipping")
            return
        }
        val bitmap = if (iconPath != null) {
            try {
                BitmapFactory.decodeFile(iconPath).also {
                    if (it == null) Log.w("MainActivity", "decodeFile returned null: $iconPath")
                }
            } catch (e: Exception) {
                Log.e("MainActivity", "decode icon failed: $e")
                null
            }
        } else null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            setTaskDescription(
                ActivityManager.TaskDescription(
                    label,
                    bitmap,
                    android.graphics.Color.parseColor("#2C2C2C")
                )
            )
            Log.d("MainActivity", "TaskDescription set: label=$label hasBitmap=${bitmap != null}")
        }
        getSharedPreferences("app_display", Context.MODE_PRIVATE).edit().apply {
            putString("custom_app_name", label)
            if (iconPath != null) {
                putString("custom_app_icon_path", iconPath)
            }
            apply()
        }
    }

    private fun applySavedAppDisplay() {
        try {
            val prefs = getSharedPreferences("app_display", Context.MODE_PRIVATE)
            val label = prefs.getString("custom_app_name", "") ?: ""
            val iconPath = prefs.getString("custom_app_icon_path", null)
            Log.d("MainActivity", "applySavedAppDisplay: label=$label iconPath=$iconPath")
            if (label.isNotEmpty() || iconPath != null) {
                setAppDisplay(label, iconPath)
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "applySavedAppDisplay failed: $e")
        }
    }

    private fun isShortcutSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val shortcutManager = getSystemService(Context.SHORTCUT_SERVICE) as ShortcutManager
            shortcutManager.isRequestPinShortcutSupported
        } catch (e: Exception) {
            Log.e("MainActivity", "isRequestPinShortcutSupported check failed: $e")
            false
        }
    }

    private fun createHomeShortcut(label: String, iconPath: String?): Boolean {
        Log.d("MainActivity", "createHomeShortcut: label=$label iconPath=$iconPath")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            Log.w("MainActivity", "createHomeShortcut: API < 26, skipping")
            return false
        }
        val shortcutManager = getSystemService(Context.SHORTCUT_SERVICE) as ShortcutManager

        if (!shortcutManager.isRequestPinShortcutSupported) {
            Log.w("MainActivity", "createHomeShortcut: requestPinShortcut not supported by launcher")
        }

        val bitmap = if (iconPath != null) {
            try {
                BitmapFactory.decodeFile(iconPath).also {
                    if (it == null) Log.w("MainActivity", "createHomeShortcut: decodeFile returned null: $iconPath")
                }
            } catch (e: Exception) {
                Log.e("MainActivity", "createHomeShortcut: decode failed: $e")
                null
            }
        } else null

        val icon = if (bitmap != null) {
            Icon.createWithBitmap(bitmap)
        } else {
            Icon.createWithResource(this, R.mipmap.ic_launcher)
        }

        val defaultLabel = packageManager.getApplicationLabel(applicationInfo).toString()
        val displayLabel = label.ifEmpty { defaultLabel }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)

        val shortcutInfo = ShortcutInfo.Builder(this, "custom_launcher")
            .setShortLabel(displayLabel)
            .setLongLabel(displayLabel)
            .setIcon(icon)
            .setIntent(launchIntent!!)
            .build()

        return try {
            val alreadyPinned = shortcutManager.pinnedShortcuts.any { it.id == "custom_launcher" }
            if (alreadyPinned) {
                shortcutManager.updateShortcuts(listOf(shortcutInfo))
                Log.d("MainActivity", "Home shortcut updated: $displayLabel")
            } else {
                shortcutManager.requestPinShortcut(shortcutInfo, null)
                Log.d("MainActivity", "Home shortcut pin requested: $displayLabel")
            }
            true
        } catch (e: Exception) {
            Log.e("MainActivity", "Home shortcut failed: $e")
            false
        }
    }
}
