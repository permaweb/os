package org.permaweb.andee

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import kotlin.concurrent.thread

internal data class AndockImageSpec(
    val transactionId: String,
    val sparseBytes: Long,
    val expandedBytes: Long,
    val expandedSha256: String,
)

/** Expands the one source-pinned Andock image resolved and supplied by BEAM. */
internal class AndeeAndockImageMaterializer(
    context: Context,
    runtimeRoot: File,
    configFile: File,
) : AutoCloseable {
    private val sourceRoot = AndeePaths.andockImagesRoot(context)
    private val root = File(AndeePaths.executionStateRoot(context), "template")
    private val template = File(root, TEMPLATE_NAME)
    private val marker = File(root, MARKER_NAME)
    private val manifestFile = File(runtimeRoot, TEMPLATE_MANIFEST_PATH)
    private val manifestDigest = sha256(manifestFile)
    private val spec = parseAndockImageSpec(
        JSONObject(configFile.readText(Charsets.UTF_8)),
        JSONObject(manifestFile.readText()),
    )
    private val lock = Any()
    @Volatile private var worker: Thread? = null
    @Volatile private var stopped = false
    @Volatile private var failureReason = "andock-default-image-not-materialized"

    val logicalBytes: Long get() = spec.expandedBytes

    fun ensure(imageId: String, imagePath: String, imageBytes: Long) {
        val source = validateSource(imageId, imagePath, imageBytes)
        if (installed()) return
        synchronized(lock) {
            check(!stopped) { "Andock image materializer is stopped" }
            if (installed()) return
            if (worker?.isAlive != true) {
                failureReason = "andock-default-image-materializing"
                worker = thread(name = "AndockImageMaterializer", isDaemon = true) {
                    expand(source)
                }
            }
        }
        throw ExecutionFailure(
            503,
            failureReason,
            mapOf("andock-default-image" to spec.transactionId),
        )
    }

    fun requireTemplate(): File {
        if (installed()) return template
        throw ExecutionFailure(
            503,
            failureReason,
            mapOf("andock-default-image" to spec.transactionId),
        )
    }

    override fun close() {
        synchronized(lock) {
            stopped = true
            worker?.interrupt()
        }
    }

    private fun validateSource(
        imageId: String,
        imagePath: String,
        imageBytes: Long,
    ): File {
        if (imageId != spec.transactionId) {
            throw ExecutionFailure(503, "andock-default-image-id-mismatch")
        }
        if (imageBytes != spec.sparseBytes) {
            throw ExecutionFailure(503, "andock-sparse-image-byte-length-mismatch")
        }
        val expected = File(sourceRoot, "$imageId.simg").canonicalFile
        val source = runCatching { File(imagePath).canonicalFile }
            .getOrElse { throw ExecutionFailure(503, "invalid-andock-image-path") }
        if (source != expected) {
            throw ExecutionFailure(503, "invalid-andock-image-path")
        }
        if (!source.isFile || !source.canRead()) {
            throw ExecutionFailure(503, "andock-default-image-not-materialized")
        }
        if (source.length() != spec.sparseBytes) {
            source.delete()
            throw ExecutionFailure(503, "andock-sparse-image-byte-length-mismatch")
        }
        return source
    }

    private fun expand(source: File) {
        val expanded = File(root, "$TEMPLATE_NAME.part")
        try {
            require(root.mkdirs() || root.isDirectory) {
                "failed-to-create-Andock-template-directory"
            }
            expanded.delete()
            require(
                root.usableSpace >= requiredExpansionSpace(spec.expandedBytes)
            ) {
                "insufficient-Andock-template-storage"
            }
            checkRunning()
            val result = source.inputStream().buffered().use { input ->
                AndroidSparseImage.expand(input, expanded)
            }
            require(result.bytes == spec.expandedBytes) {
                "Andock-template-byte-length-mismatch"
            }
            require(result.sha256 == spec.expandedSha256) {
                "Andock-template-digest-mismatch"
            }
            require(expanded.setReadOnly()) { "failed-to-protect-Andock-template" }
            Os.rename(expanded.absolutePath, template.absolutePath)
            writeMarker()
            syncDirectory(root)
            failureReason = ""
            Log.i(TAG, "Andock default image expanded from ${spec.transactionId}")
        } catch (failure: Throwable) {
            if (!stopped) {
                failureReason = normalizeFailure(failure)
                Log.e(TAG, "Andock default image expansion failed", failure)
            }
        } finally {
            worker = null
            expanded.delete()
        }
    }

    private fun installed(): Boolean {
        if (!template.isFile || template.length() != spec.expandedBytes || !marker.isFile) {
            return false
        }
        return runCatching {
            val value = JSONObject(marker.readText())
            value.getString("transaction-id") == spec.transactionId &&
                value.getString("manifest-sha256") == manifestDigest &&
                value.getString("image-sha256") == spec.expandedSha256
        }.getOrDefault(false)
    }

    private fun writeMarker() {
        val partial = File(root, "$MARKER_NAME.part")
        partial.delete()
        val bytes = JSONObject()
            .put("transaction-id", spec.transactionId)
            .put("manifest-sha256", manifestDigest)
            .put("image-sha256", spec.expandedSha256)
            .toString()
            .toByteArray(Charsets.UTF_8)
        try {
            FileOutputStream(partial).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            Os.rename(partial.absolutePath, marker.absolutePath)
        } finally {
            bytes.fill(0)
            partial.delete()
        }
    }

    private fun checkRunning() {
        if (stopped || Thread.currentThread().isInterrupted) {
            throw InterruptedException("Andock-materialization-stopped")
        }
    }

    private fun normalizeFailure(failure: Throwable): String = failure.message
        ?.lowercase()
        ?.replace(Regex("[^a-z0-9-]+"), "-")
        ?.trim('-')
        ?.takeIf(String::isNotEmpty)
        ?: "andock-default-image-materialization-failed"

    private companion object {
        const val TAG = "AndockImage"
        const val TEMPLATE_NAME = "andock-ubuntu-arm64.ext4"
        const val MARKER_NAME = ".andock-template.json"
        const val TEMPLATE_MANIFEST_PATH =
            "execution/andock/andock-ubuntu-arm64.ext4.manifest.json"
    }
}

internal fun parseAndockImageSpec(config: JSONObject, manifest: JSONObject): AndockImageSpec {
    val transactionId = config.optString("andock-default-image")
    require(ARWEAVE_ID.matches(transactionId)) { "invalid andock-default-image" }
    require(manifest.getString("architecture") == "arm64") {
        "Andock filesystem template architecture is not ARM64"
    }
    require(manifest.getString("sparse-image-format") == "android-sparse-v1") {
        "unsupported Andock sparse image format"
    }
    val sparseBytes = manifest.getLong("sparse-image-bytes")
    val expandedBytes = manifest.getLong("image-logical-bytes")
    require(sparseBytes in 1..expandedBytes) { "invalid Andock sparse image size" }
    require(expandedBytes in MIN_TEMPLATE_BYTES..MAX_TEMPLATE_BYTES) {
        "invalid Andock filesystem template size"
    }
    val expandedSha256 = manifest.getString("image-sha256")
    require(SHA256.matches(expandedSha256)) {
        "invalid Andock filesystem template digest"
    }
    return AndockImageSpec(
        transactionId,
        sparseBytes,
        expandedBytes,
        expandedSha256,
    )
}

internal fun requiredExpansionSpace(expandedBytes: Long): Long =
    Math.addExact(expandedBytes, ANDOCK_MATERIALIZATION_RESERVE_BYTES)

private fun sha256(file: File): String {
    require(file.isFile) { "missing Andock filesystem template manifest" }
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    file.inputStream().use { source ->
        while (true) {
            val read = source.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    buffer.fill(0)
    return digest.digest().toHex()
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

private fun syncDirectory(directory: File) {
    val descriptor = Os.open(
        directory.absolutePath,
        OsConstants.O_RDONLY or OsConstants.O_CLOEXEC,
        0,
    )
    try {
        Os.fsync(descriptor)
    } finally {
        Os.close(descriptor)
    }
}

private val ARWEAVE_ID = Regex("^[A-Za-z0-9_-]{43}$")
private val SHA256 = Regex("^[a-f0-9]{64}$")
private const val MIN_TEMPLATE_BYTES = 1024L * 1024 * 1024
private const val MAX_TEMPLATE_BYTES = 64L * 1024 * 1024 * 1024
private const val ANDOCK_MATERIALIZATION_RESERVE_BYTES = 512L * 1024 * 1024
