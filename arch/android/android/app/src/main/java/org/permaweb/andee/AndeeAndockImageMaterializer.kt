package org.permaweb.andee

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Log
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread

internal data class AndockImageSpec(
    val transactionId: String,
    val sparseBytes: Long,
    val sparseSha256: String,
    val expandedBytes: Long,
    val expandedSha256: String,
)

/** Materializes the one source-pinned Andock rootfs through its measured Arweave ID. */
internal class AndeeAndockImageMaterializer(
    context: Context,
    runtimeRoot: File,
    configFile: File,
) : AutoCloseable {
    private val root = File(AndeePaths.executionStateRoot(context), "template")
    private val template = File(root, TEMPLATE_NAME)
    private val marker = File(root, MARKER_NAME)
    private val manifestFile = File(runtimeRoot, TEMPLATE_MANIFEST_PATH)
    private val manifestDigest = sha256(manifestFile)
    private val config = JSONObject(configFile.readText(Charsets.UTF_8))
    private val spec = parseAndockImageSpec(config, JSONObject(manifestFile.readText()))
    private val gateway = parseGateway(config)
    private val lock = Any()
    @Volatile private var state = State.IDLE
    @Volatile private var failureReason = "andock-default-image-not-materialized"
    @Volatile private var worker: Thread? = null
    @Volatile private var connection: HttpURLConnection? = null

    val logicalBytes: Long get() = spec.expandedBytes

    fun start() {
        synchronized(lock) {
            check(state != State.STOPPED) { "Andock image materializer is stopped" }
            if (state == State.READY || worker?.isAlive == true) return
            require(root.mkdirs() || root.isDirectory) {
                "failed to create Andock template directory"
            }
            if (installed()) {
                state = State.READY
                failureReason = ""
                Log.i(TAG, "Andock template ready at ${template.absolutePath}")
                return
            }
            state = State.MATERIALIZING
            failureReason = "andock-default-image-materializing"
            worker = thread(name = "AndockImageMaterializer", isDaemon = true) {
                materialize()
            }
        }
    }

    fun requireTemplate(): File {
        if (state == State.READY && installed()) return template
        synchronized(lock) {
            if (state == State.READY) state = State.IDLE
        }
        start()
        throw ExecutionFailure(
            503,
            failureReason,
            mapOf("andock-default-image" to spec.transactionId),
        )
    }

    override fun close() {
        synchronized(lock) {
            state = State.STOPPED
            connection?.disconnect()
            worker?.interrupt()
        }
    }

    private fun materialize() {
        val sparse = File(root, "$TEMPLATE_NAME.simg.part")
        val expanded = File(root, "$TEMPLATE_NAME.part")
        try {
            expanded.delete()
            marker.delete()
            template.delete()
            if (sparse.length() > spec.sparseBytes) sparse.delete()
            require(
                root.usableSpace >= requiredMaterializationSpace(
                    spec.sparseBytes,
                    spec.expandedBytes,
                    sparse.length(),
                )
            ) {
                "insufficient-Andock-template-storage"
            }
            download(sparse)
            checkRunning()
            val result = sparse.inputStream().buffered().use { input ->
                AndroidSparseImage.expand(input, expanded)
            }
            require(result.bytes == spec.expandedBytes) {
                "Andock-template-byte-length-mismatch"
            }
            require(result.sha256 == spec.expandedSha256) {
                "Andock-template-digest-mismatch"
            }
            require(expanded.setReadOnly()) { "failed-to-protect-Andock-template" }
            require(expanded.renameTo(template)) { "failed-to-install-Andock-template" }
            writeMarker()
            syncDirectory(root)
            sparse.delete()
            synchronized(lock) {
                if (state != State.STOPPED) {
                    state = State.READY
                    failureReason = ""
                }
            }
            Log.i(TAG, "Andock default image materialized from ${spec.transactionId}")
        } catch (failure: Throwable) {
            if (state != State.STOPPED) {
                failureReason = normalizeFailure(failure)
                state = State.FAILED
                Log.e(TAG, "Andock default image materialization failed", failure)
            }
        } finally {
            connection?.disconnect()
            connection = null
            worker = null
            expanded.delete()
        }
    }

    private fun download(output: File) {
        var count = output.length()
        val digest = MessageDigest.getInstance("SHA-256")
        if (count > 0L) {
            output.inputStream().buffered().use { source ->
                val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                while (true) {
                    checkRunning()
                    val read = source.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
                buffer.fill(0)
            }
        }
        if (count == spec.sparseBytes) {
            if (digest.digest().toHex() == spec.sparseSha256) return
            output.delete()
            error("Andock-sparse-image-digest-mismatch")
        }
        val request = URL("$gateway/${spec.transactionId}").openConnection() as HttpURLConnection
        connection = request
        request.instanceFollowRedirects = true
        request.connectTimeout = CONNECT_TIMEOUT_MS
        request.readTimeout = READ_TIMEOUT_MS
        request.setRequestProperty("Accept", "application/octet-stream")
        if (count > 0L) request.setRequestProperty("Range", "bytes=$count-")
        val response = request.responseCode
        val append = response == HttpURLConnection.HTTP_PARTIAL &&
            request.getHeaderField("Content-Range")?.startsWith("bytes $count-") == true
        if (count > 0L && response == HttpURLConnection.HTTP_OK) {
            count = 0L
            digest.reset()
        } else if (response !in 200..299 || (count > 0L && !append)) {
            error("Andock-default-image-fetch-failed")
        }
        var corrupt = false
        try {
            FileOutputStream(output, append).use { file ->
                val destination = BufferedOutputStream(file, DOWNLOAD_BUFFER_BYTES)
                try {
                    request.inputStream.use { source ->
                        val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                        while (true) {
                            checkRunning()
                            val read = source.read(buffer)
                            if (read < 0) break
                            count += read
                            if (count > spec.sparseBytes) {
                                corrupt = true
                                error("Andock-sparse-image-byte-length-mismatch")
                            }
                            digest.update(buffer, 0, read)
                            destination.write(buffer, 0, read)
                            if (count % PROGRESS_INTERVAL_BYTES < read) {
                                Log.i(TAG, "Andock image download: $count/${spec.sparseBytes} bytes")
                            }
                        }
                        buffer.fill(0)
                    }
                    destination.flush()
                    file.fd.sync()
                } finally {
                    runCatching { destination.close() }
                }
            }
        } catch (failure: Throwable) {
            if (corrupt) output.delete()
            throw failure
        }
        if (count != spec.sparseBytes) {
            error("Andock-sparse-image-byte-length-mismatch")
        }
        if (digest.digest().toHex() != spec.sparseSha256) {
            output.delete()
            error("Andock-sparse-image-digest-mismatch")
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
            require(partial.renameTo(marker)) { "failed-to-install-Andock-template-marker" }
        } finally {
            bytes.fill(0)
            partial.delete()
        }
    }

    private fun checkRunning() {
        if (state == State.STOPPED || Thread.currentThread().isInterrupted) {
            throw InterruptedException("Andock-materialization-stopped")
        }
    }

    private fun normalizeFailure(failure: Throwable): String = failure.message
        ?.lowercase()
        ?.replace(Regex("[^a-z0-9-]+"), "-")
        ?.trim('-')
        ?.takeIf(String::isNotEmpty)
        ?: "andock-default-image-materialization-failed"

    private enum class State { IDLE, MATERIALIZING, READY, FAILED, STOPPED }

    private companion object {
        const val TAG = "AndockImage"
        const val TEMPLATE_NAME = "andock-ubuntu-arm64.ext4"
        const val MARKER_NAME = ".andock-template.json"
        const val TEMPLATE_MANIFEST_PATH =
            "execution/andock/andock-ubuntu-arm64.ext4.manifest.json"
        const val CONNECT_TIMEOUT_MS = 30_000
        const val READ_TIMEOUT_MS = 30_000
        const val DOWNLOAD_BUFFER_BYTES = 1024 * 1024
        const val PROGRESS_INTERVAL_BYTES = 64L * 1024 * 1024
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
    val sparseSha256 = manifest.getString("sparse-image-sha256")
    val expandedSha256 = manifest.getString("image-sha256")
    require(SHA256.matches(sparseSha256) && SHA256.matches(expandedSha256)) {
        "invalid Andock filesystem template digest"
    }
    return AndockImageSpec(
        transactionId,
        sparseBytes,
        sparseSha256,
        expandedBytes,
        expandedSha256,
    )
}

internal fun requiredMaterializationSpace(
    sparseBytes: Long,
    expandedBytes: Long,
    downloadedBytes: Long = 0L,
): Long {
    require(downloadedBytes in 0..sparseBytes)
    return Math.addExact(
        Math.addExact(expandedBytes, sparseBytes - downloadedBytes),
        ANDOCK_MATERIALIZATION_RESERVE_BYTES,
    )
}

private fun parseGateway(config: JSONObject): String {
    val value = config.optString("gateway", DEFAULT_GATEWAY).trimEnd('/')
    val uri = URI(value)
    require(uri.scheme in setOf("http", "https") && uri.host != null) {
        "invalid Arweave gateway"
    }
    require(uri.userInfo == null && uri.query == null && uri.fragment == null) {
        "invalid Arweave gateway"
    }
    return value
}

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
private const val DEFAULT_GATEWAY = "https://arweave.net"
private const val MIN_TEMPLATE_BYTES = 1024L * 1024 * 1024
private const val MAX_TEMPLATE_BYTES = 64L * 1024 * 1024 * 1024
private const val ANDOCK_MATERIALIZATION_RESERVE_BYTES = 512L * 1024 * 1024
