package org.permaweb.andee

import android.content.Context
import android.util.Log
import java.io.File
import java.security.MessageDigest
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
        val baseApk = File(context.applicationInfo.sourceDir)
        val apks = listOfNotNull(context.applicationInfo.sourceDir) +
            context.applicationInfo.splitSourceDirs.orEmpty().toList()

        val baseConfig = File(runtimeRoot, "config/andee.json")
        require(baseConfig.isFile) { "missing AndEE config: ${baseConfig.absolutePath}" }
        val config = AndeeBootConfigStore.effectiveConfigFile(context, baseConfig)

        val runDir = AndeePaths.runDir(context)
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
                builder.environment()["ANDEE_CRYPTO_SOCKET"] = AndeePaths.cryptoSocketName(context)
                builder.environment()["ANDEE_RUNTIME_ROOT"] = runtimeRoot.absolutePath
                builder.environment()["ANDEE_PACKAGE_NAME"] = context.packageName
                builder.environment()["ANDEE_VERSION_NAME"] = BuildConfig.VERSION_NAME
                builder.environment()["ANDEE_VERSION_CODE"] = BuildConfig.VERSION_CODE.toString()
                builder.environment()["ANDEE_RELEASE_DIGEST"] = releaseDigest(context)
                builder.environment()["ANDEE_NATIVE_LIB_DIR"] = context.applicationInfo.nativeLibraryDir
                builder.environment()["ANDEE_ANDROID_ABI"] = android.os.Build.SUPPORTED_ABIS.first()
                builder.environment()["ANDEE_BOOT_CONFIG"] = config.absolutePath
                builder.environment()["ANDEE_NODE_WALLET"] =
                    AndeePaths.nodeWalletFile(context).absolutePath
                builder.environment()["ANDEE_RUNTIME_ZIP_SHA256"] = runtimeZipSha256()
                builder.environment()["ANDEE_BASE_APK_SHA256"] = sha256(baseApk)
                builder.environment()["ANDEE_APK_SET_SHA256"] = digestFileSet(apks.map(::File))
                builder.environment()["ANDEE_NATIVE_LAUNCHER_SHA256"] = sha256(executable)
                builder.environment()["ANDEE_NATIVE_LIBRARIES_SHA256"] =
                    digestFileSet(nativeLibraries())
                builder.environment()["ANDEE_ENCRYPTED_STORE_ROOT"] =
                    AndeePaths.encryptedStoreRoot(context).absolutePath
                builder.environment()["ANDEE_EXECUTION_SOCKET"] =
                    AndeePaths.executionSocketFile(context).absolutePath
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
        private const val EXECUTABLE_NAME = "libandee_hyperbeam.so"
        private val RUNTIME_PROCESS_NAMES = setOf(
            "beam.smp",
            "erlexec",
            "libandee_hyperbeam.so",
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

        private fun sha256(file: File): String =
            base64Url(fileSha256(file))

        private fun digestFileSet(files: List<File>): String {
            val md = MessageDigest.getInstance("SHA-256")
            files.sortedBy { it.name }.forEach { file ->
                md.update(file.name.toByteArray(Charsets.UTF_8))
                md.update(0)
                md.update(file.length().toString().toByteArray(Charsets.UTF_8))
                md.update(0)
                md.update(fileSha256(file))
            }
            return base64Url(md.digest())
        }

        private fun fileSha256(file: File): ByteArray {
            val md = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            file.inputStream().use { input ->
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    md.update(buffer, 0, read)
                }
            }
            return md.digest()
        }

        private fun releaseDigest(context: Context): String {
            val packageInfo = context.packageManager.getPackageInfo(
                context.packageName,
                android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES,
            )
            val md = MessageDigest.getInstance("SHA-256")
            packageInfo.signingInfo?.apkContentsSigners.orEmpty().forEach {
                md.update(it.toByteArray())
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }

        private fun base64Url(bytes: ByteArray): String =
            android.util.Base64.encodeToString(
                bytes,
                android.util.Base64.URL_SAFE or
                    android.util.Base64.NO_PADDING or
                    android.util.Base64.NO_WRAP,
            )
    }

    private fun runtimeZipSha256(): String =
        base64Url(hexToBytes(AndeePaths.runtimeZipMarker(context).readText().trim()))

    private fun nativeLibraries(): List<File> =
        File(context.applicationInfo.nativeLibraryDir)
            .listFiles { file -> file.isFile && file.name.endsWith(".so") }
            .orEmpty()
            .toList()

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "bad runtime zip digest marker" }
        return ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }
}
