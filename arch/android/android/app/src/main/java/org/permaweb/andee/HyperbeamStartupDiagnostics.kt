package org.permaweb.andee

import java.io.File
import java.io.PrintWriter
import java.io.RandomAccessFile

/** Existing service-dump projection for explicitly measured diagnostic APKs only. */
internal class HyperbeamStartupDiagnostics(runDir: File) {
    private val launchedAt = System.currentTimeMillis()
    private val logs = listOf("hyperbeam.stdout", "hyperbeam.stderr").map { name ->
        File(runDir, name).let { file -> file to file.length() }
    }
    var process: Process? = null

    fun dump(enabled: Boolean, args: Array<out String>, writer: PrintWriter): Boolean {
        if (!enabled || !args.contentEquals(arrayOf("--runtime-logs"))) return false
        writer.println("startup-diagnostics=true launch-time-ms=$launchedAt")
        val child = process
        // Android's public Process.toString includes its PID; pid() is not available on API 36.
        writer.println("process=${child?.toString()?.take(160) ?: "not-started"}")
        writer.println("alive=${child?.isAlive == true}")
        val exit = child?.let { runCatching { it.exitValue() }.getOrNull() }
        writer.println("exit-code=${exit ?: "unavailable"}")
        for ((file, offset) in logs) {
            writer.println("--- ${file.name}: current launch, last $MAX_LOG_BYTES bytes ---")
            try {
                if (!file.isFile) {
                    writer.println("unavailable")
                    continue
                }
                RandomAccessFile(file, "r").use { input ->
                    val end = input.length()
                    if (end < offset) {
                        writer.println("log was truncated after launch")
                    } else {
                        val start = maxOf(offset, end - MAX_LOG_BYTES)
                        if (start > offset) writer.println("[earlier launch output omitted]")
                        input.seek(start)
                        val bytes = ByteArray((end - start).toInt())
                        input.readFully(bytes)
                        writer.println(bytes.toString(Charsets.UTF_8))
                    }
                }
            } catch (_: java.io.IOException) {
                writer.println("unavailable (I/O error)")
            } catch (_: SecurityException) {
                writer.println("unavailable (permission denied)")
            }
        }
        return true
    }

    companion object {
        const val MAX_LOG_BYTES = 16 * 1024
    }
}
