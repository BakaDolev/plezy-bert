package com.edde746.plezy

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Process
import android.os.StatFs
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Fork-only (never upstream): hands an update the fork's updater downloaded to Android's own
 * package installer, which shows its confirmation and keeps the user's data (same package, same
 * signing key, higher version code).
 *
 * Only APKs inside `filesDir/updates` are handed over; the Dart side has already checked their
 * size and SHA-256 against the release feed.
 */
internal class AppUpdateChannel(private val activity: Activity) {
  companion object {
    private const val TAG = "AppUpdateChannel"
    private const val CHANNEL = "com.plezy/app_update"
    private const val FILE_PROVIDER_AUTHORITY = "com.edde746.plezy.fileprovider"
    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    const val UPDATES_FOLDER = "updates"

    /** Whether [file] is an existing file inside [filesDir]/updates (no `..` escapes). */
    fun isInUpdatesFolder(file: File, filesDir: File): Boolean {
      val updates = File(filesDir, UPDATES_FOLDER).canonicalPath + File.separator
      return file.isFile && file.canonicalPath.startsWith(updates)
    }

    /** The system installer's "install this APK" request, readable through [uri] only. */
    fun installIntent(uri: Uri): Intent = Intent(Intent.ACTION_VIEW).apply {
      setDataAndType(uri, APK_MIME_TYPE)
      // The read grant rides the ClipData too, or some installers can't open the file.
      clipData = ClipData.newRawUri("", uri)
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
  }

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      // The running process, not the CPU: a 64-bit TV running the 32-bit APK must keep that one.
      "is64Bit" -> result.success(Process.is64Bit())
      // The only folder installApk accepts; created on demand.
      "updatesDir" -> result.success(File(activity.filesDir, UPDATES_FOLDER).apply { mkdirs() }.path)
      "freeBytes" -> result.success(StatFs(activity.filesDir.path).availableBytes)
      "canInstall" -> result.success(canInstall())
      "openInstallSettings" -> result.success(openInstallSettings())
      "isSamsung" -> result.success(Build.MANUFACTURER.equals("samsung", ignoreCase = true))
      "installApk" -> {
        val path = call.argument<String>("path")
        if (path == null) {
          result.error("bad_args", "path is required", null)
        } else {
          result.success(installApk(File(path)))
        }
      }
      else -> result.notImplemented()
    }
  }

  private fun canInstall(): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

  /**
   * Opens the screen that lets Plezy install apps, or the closest one this device has (TV
   * builds often lack the per-app screen). Returns which one opened, or null.
   */
  private fun openInstallSettings(): String? {
    val attempts = buildList {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        add("app" to Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
        add("list" to Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES))
      }
      add("security" to Intent(Settings.ACTION_SECURITY_SETTINGS))
      add("settings" to Intent(Settings.ACTION_SETTINGS))
    }
    for ((name, intent) in attempts) {
      try {
        activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return name
      } catch (e: ActivityNotFoundException) {
        Log.d(TAG, "No $name settings screen", e)
      } catch (e: SecurityException) {
        Log.d(TAG, "The $name settings screen refused to open", e)
      }
    }
    return null
  }

  private fun installApk(file: File): Boolean {
    if (!isInUpdatesFolder(file, activity.filesDir)) {
      Log.w(TAG, "Refusing to install an APK from outside the updates folder")
      return false
    }
    return try {
      activity.startActivity(installIntent(FileProvider.getUriForFile(activity, FILE_PROVIDER_AUTHORITY, file)))
      true
    } catch (e: ActivityNotFoundException) {
      Log.w(TAG, "No package installer", e)
      false
    } catch (e: IllegalArgumentException) {
      Log.w(TAG, "FileProvider cannot share the update", e)
      false
    }
  }
}
