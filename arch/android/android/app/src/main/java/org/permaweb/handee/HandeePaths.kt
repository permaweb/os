package org.permaweb.handee

import android.content.Context
import java.io.File

object HandeePaths {
    fun runtimeRoot(context: Context): File = File(context.noBackupFilesDir, "handee-runtime")
    fun runtimeZipMarker(context: Context): File = File(runtimeRoot(context), ".handee-runtime.sha256")
    fun runDir(context: Context): File = File(context.noBackupFilesDir, "run")
    fun encryptedStoreRoot(context: Context): File = File(context.noBackupFilesDir, "encrypted-zones")
    fun cryptoSocketFile(context: Context): File = File(runDir(context), "handee-crypto.sock")
    fun cryptoSocketName(context: Context): String = cryptoSocketFile(context).absolutePath
}
