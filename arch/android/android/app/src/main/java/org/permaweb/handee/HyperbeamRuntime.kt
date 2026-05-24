package org.permaweb.handee

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.TimeUnit

class HyperbeamRuntime(
    private val context: Context,
    private val runtimeRoot: File,
) : AutoCloseable {
    private var process: Process? = null

    fun start() {
        if (process?.isAlive == true) return

        val executable = File(context.applicationInfo.nativeLibraryDir, EXECUTABLE_NAME)
        require(executable.isFile && executable.canExecute()) {
            "HyperBEAM executable is not installed in nativeLibraryDir: ${executable.absolutePath}"
        }

        val baseConfig = File(runtimeRoot, "config/handee.json")
        require(baseConfig.isFile) { "missing HandEE config: ${baseConfig.absolutePath}" }
        val config = HandeeBootConfigStore.effectiveConfigFile(context, baseConfig)

        val runDir = HandeePaths.runDir(context)
        runDir.mkdirs()

        process = ProcessBuilder(
            executable.absolutePath,
            "--root",
            runtimeRoot.absolutePath,
            "--config",
            config.absolutePath,
        )
            .directory(runtimeRoot)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(File(runDir, "hyperbeam.stdout")))
            .redirectError(ProcessBuilder.Redirect.appendTo(File(runDir, "hyperbeam.stderr")))
            .also { builder ->
                builder.environment()["HANDEE_CRYPTO_SOCKET"] = HandeePaths.cryptoSocketName(context)
                builder.environment()["HANDEE_RUNTIME_ROOT"] = runtimeRoot.absolutePath
                builder.environment()["HANDEE_PACKAGE_NAME"] = context.packageName
                builder.environment()["HANDEE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                builder.environment()["HANDEE_ANDROID_ABI"] = android.os.Build.SUPPORTED_ABIS.first()
                builder.environment()["HANDEE_BOOT_CONFIG"] = config.absolutePath
                builder.environment()["HANDEE_ENCRYPTED_STORE_ROOT"] =
                    HandeePaths.encryptedStoreRoot(context).absolutePath
            }
            .start()

        Log.i(TAG, "HyperBEAM native launcher started with config ${config.absolutePath}")
    }

    fun isAlive(): Boolean = process?.isAlive == true

    override fun close() {
        val current = process ?: return
        process = null
        if (current.isAlive) {
            current.destroy()
            if (!current.waitFor(2, TimeUnit.SECONDS)) {
                current.destroyForcibly()
                current.waitFor(2, TimeUnit.SECONDS)
            }
        }
        killResidualRuntimeProcesses(context)
        Log.i(TAG, "HyperBEAM native launcher stopped")
    }

    companion object {
        private const val TAG = "HyperbeamRuntime"
        private const val EXECUTABLE_NAME = "libhandee_hyperbeam.so"
        private val RUNTIME_PROCESS_NAMES = setOf(
            "beam.smp",
            "erlexec",
            "libhandee_hyperbeam.so",
        )

        fun killResidualRuntimeProcesses(context: Context): List<Int> {
            val uid = context.applicationInfo.uid
            val killed = mutableListOf<Int>()
            File("/proc").listFiles().orEmpty().forEach { procDir ->
                val pid = procDir.name.toIntOrNull() ?: return@forEach
                if (pid == android.os.Process.myPid()) return@forEach
                if (procUid(procDir) != uid) return@forEach
                val command = procCommand(procDir)
                if (RUNTIME_PROCESS_NAMES.none { command.contains(it) }) return@forEach
                runCatching {
                    android.os.Process.killProcess(pid)
                    killed.add(pid)
                }.onFailure { exc ->
                    Log.w(TAG, "failed to kill residual runtime process $pid $command", exc)
                }
            }
            if (killed.isNotEmpty()) {
                runCatching { Thread.sleep(100L) }
                Log.i(TAG, "killed residual HyperBEAM runtime processes: $killed")
            }
            return killed
        }

        private fun procUid(procDir: File): Int? {
            return runCatching {
                File(procDir, "status").useLines { lines ->
                    lines.firstOrNull { it.startsWith("Uid:") }
                        ?.trim()
                        ?.split(Regex("\\s+"))
                        ?.getOrNull(1)
                        ?.toIntOrNull()
                }
            }.getOrNull()
        }

        private fun procCommand(procDir: File): String {
            val cmdline = runCatching {
                File(procDir, "cmdline")
                    .readBytes()
                    .filter { it != 0.toByte() }
                    .toByteArray()
                    .toString(Charsets.UTF_8)
            }.getOrDefault("")
            if (cmdline.isNotBlank()) return cmdline
            return runCatching { File(procDir, "comm").readText().trim() }.getOrDefault("")
        }
    }
}
