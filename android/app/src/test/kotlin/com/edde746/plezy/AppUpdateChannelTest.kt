package com.edde746.plezy

import android.content.Intent
import android.net.Uri
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class AppUpdateChannelTest {
  private val filesDir: File = Files.createTempDirectory("files").toFile()
  private val updates = File(filesDir, AppUpdateChannel.UPDATES_FOLDER).apply { mkdirs() }

  @Test
  fun onlyFilesInsideTheUpdatesFolderAreHandedOver() {
    val apk = File(updates, "PlezyFork-2.23.0-175-phone-arm64-v8a.apk").apply { writeText("apk") }
    val elsewhere = File(filesDir, "other.apk").apply { writeText("apk") }
    val escaping = File(updates, "../other.apk")
    val sibling = File(filesDir, "updates-evil").apply { mkdirs() }.let { File(it, "x.apk").apply { writeText("apk") } }

    assertTrue(AppUpdateChannel.isInUpdatesFolder(apk, filesDir))
    assertFalse(AppUpdateChannel.isInUpdatesFolder(elsewhere, filesDir))
    assertFalse(AppUpdateChannel.isInUpdatesFolder(escaping, filesDir))
    assertFalse(AppUpdateChannel.isInUpdatesFolder(sibling, filesDir))
    assertFalse(AppUpdateChannel.isInUpdatesFolder(File(updates, "missing.apk"), filesDir))
    assertFalse(AppUpdateChannel.isInUpdatesFolder(updates, filesDir))
  }

  @Test
  fun theInstallRequestGrantsReadAccessToThatOneApk() {
    val uri = Uri.parse("content://com.edde746.plezy.fileprovider/app_files/updates/x.apk")
    val intent = AppUpdateChannel.installIntent(uri)

    assertEquals(Intent.ACTION_VIEW, intent.action)
    assertEquals(uri, intent.data)
    assertEquals("application/vnd.android.package-archive", intent.type)
    assertEquals(uri, intent.clipData!!.getItemAt(0).uri)
    assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
    assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
  }
}
