package org.permaweb.andee

import android.content.Context
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

class RuntimeExtractor(private val context: Context) {
    fun extractIfNeeded(): File {
        val root = AndeePaths.runtimeRoot(context)
        val assetBytes = context.assets.open(RUNTIME_ZIP).use { it.readBytes() }
        val digest = sha256(assetBytes)
        val marker = AndeePaths.runtimeZipMarker(context)
        if (root.isDirectory && marker.isFile && marker.readText() == digest) {
            Log.i(TAG, "runtime ready at ${root.absolutePath}")
            return root
        }

        val tmp = File(context.noBackupFilesDir, "andee-runtime.tmp")
        tmp.deleteRecursively()
        tmp.mkdirs()
        ZipInputStream(assetBytes.inputStream()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val out = File(tmp, entry.name)
                val canonicalRoot = tmp.canonicalFile.toPath()
                val canonicalOut = out.canonicalFile.toPath()
                require(canonicalOut.startsWith(canonicalRoot)) {
                    "runtime zip entry escapes destination: ${entry.name}"
                }
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    out.outputStream().use { output -> zip.copyTo(output) }
                }
                zip.closeEntry()
            }
        }

        marker.parentFile?.mkdirs()
        File(tmp, ".andee-runtime.sha256").writeText(digest)
        root.deleteRecursively()
        if (!tmp.renameTo(root)) {
            throw IllegalStateException("failed to install runtime atomically")
        }
        Log.i(TAG, "runtime extracted to ${root.absolutePath}")
        return root
    }

    private fun sha256(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        return md.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "RuntimeExtractor"
        private const val RUNTIME_ZIP = "andee-runtime.zip"
    }
}
