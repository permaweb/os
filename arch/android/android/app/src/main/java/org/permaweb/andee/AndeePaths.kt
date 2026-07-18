package org.permaweb.andee

import android.content.Context
import java.io.File

object AndeePaths {
    fun runtimeRoot(context: Context): File = File(context.noBackupFilesDir, "andee-runtime")
    fun runtimeZipMarker(context: Context): File = File(runtimeRoot(context), ".andee-runtime.sha256")
    fun runDir(context: Context): File = File(context.noBackupFilesDir, "run")
    fun nodeWalletFile(context: Context): File =
        File(context.noBackupFilesDir, "node-identity/hyperbeam-key.json")
    fun executionStateRoot(context: Context): File =
        File(context.noBackupFilesDir, "execution-state")
    fun executionSocketFile(context: Context): File =
        File(runDir(context), "andee-execution.sock")
    fun encryptedStoreRoot(context: Context): File = File(context.noBackupFilesDir, "encrypted-zones")
    fun cryptoSocketFile(context: Context): File = File(runDir(context), "andee-crypto.sock")
    fun cryptoSocketName(context: Context): String = cryptoSocketFile(context).absolutePath
}
