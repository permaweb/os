package org.permaweb.andee

import android.content.Context
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

/** Owns member images, serialization, isolated workers, and local transport. */
internal class AndeeExecutionManager(
    private val context: Context,
    runtimeRoot: File,
) : AutoCloseable {
    private val storage = AndeeExecutionStorage(context, runtimeRoot)
    private val workers = AndeeIsolatedExecutionPool(context)
    private val server = AndeeExecutionServer(context, ::dispatch, ::failureResponse)
    private val locks = mutableMapOf<String, MemberLock>()
    @Volatile private var running = false

    fun start() {
        check(!running) { "execution manager is already running" }
        storage.start()
        running = true
        try {
            server.start()
        } catch (failure: Throwable) {
            running = false
            workers.close()
            throw failure
        }
    }

    override fun close() {
        running = false
        server.close()
        workers.close()
    }

    private fun dispatch(request: JSONObject): JSONObject {
        check(running) { "execution manager is stopped" }
        require(request.optString("protocol") == PROTOCOL) { "unsupported-protocol" }
        val action = request.getString("action")
        val memberId = validateMemberId(request.getString("member-id"))
        if (action == "stop") {
            workers.stop(memberId)
            return success(JSONObject())
        }
        if (action == "destroy") workers.stop(memberId)
        return withMemberLock(memberId) {
            when (action) {
                "read" -> read(memberId, normalizeGuestPath(request.getString("path")))
                "write" -> write(
                    memberId,
                    normalizeGuestPath(request.getString("path")),
                    decode(request.getString("content")),
                )
                "list" -> list(memberId, normalizeGuestPath(request.getString("path")))
                "exec" -> execute(
                    memberId,
                    normalizeGuestPath(request.optString("cwd", "/root")),
                    request.getString("command"),
                    request.optInt("timeout-ms", DEFAULT_TIMEOUT_MS)
                        .coerceIn(1, AndeeExecutionPolicy.MAX_TIMEOUT_MS),
                    request.optBoolean("allow-network", false),
                )
                "destroy" -> {
                    storage.destroy(memberId)
                    success(JSONObject())
                }
                else -> throw ExecutionFailure(404, "unknown-action")
            }
        }
    }

    private fun read(memberId: String, path: String): JSONObject {
        val result = command(
            memberId,
            "/root",
            "cat -- ${shellQuote(path)}",
            READ_TIMEOUT_MS,
            false,
        )
        if (result.status.optInt("exit-code") != 0) throw fileFailure(result.error())
        if (result.truncated) throw ExecutionFailure(413, "file-too-large")
        return success(JSONObject().put("content", encode(result.output)))
    }

    private fun write(memberId: String, path: String, content: ByteArray): JSONObject {
        try {
            val parent = path.substringBeforeLast('/', "/").ifEmpty { "/" }
            val result = command(
                memberId,
                "/root",
                "mkdir -p -- ${shellQuote(parent)} && cat > ${shellQuote(path)}",
                WRITE_TIMEOUT_MS,
                false,
                content,
            )
            if (result.status.optInt("exit-code") != 0) {
                throw ExecutionFailure(500, result.error().ifEmpty { "write-failed" })
            }
            return success(JSONObject())
        } finally {
            content.fill(0)
        }
    }

    private fun list(memberId: String, path: String): JSONObject {
        val result = command(
            memberId,
            "/root",
            "find ${shellQuote(path)} -mindepth 1 -maxdepth 1 " +
                "-printf '%f\\0%y\\0%s\\0%T@\\0'",
            LIST_TIMEOUT_MS,
            false,
        )
        if (result.status.optInt("exit-code") != 0) throw fileFailure(result.error())
        if (result.truncated) throw ExecutionFailure(413, "directory-listing-too-large")
        return success(JSONObject().put("entries", parseEntries(result.output)))
    }

    private fun execute(
        memberId: String,
        cwd: String,
        command: String,
        timeoutMs: Int,
        allowNetwork: Boolean,
    ): JSONObject {
        val result = command(
            memberId,
            cwd,
            "umask 022; $command",
            timeoutMs,
            true,
            allowNetwork = allowNetwork,
        )
        return success(
            JSONObject()
                .put("output", encode(result.output))
                .put("exit-code", result.status.optInt("exit-code"))
                .put("timed-out", result.status.optBoolean("timed-out"))
                .put("cancelled", result.status.optBoolean("cancelled"))
                .put("output-truncated", result.truncated),
        )
    }

    private fun command(
        memberId: String,
        cwd: String,
        command: String,
        timeoutMs: Int,
        mergeError: Boolean,
        input: ByteArray? = null,
        allowNetwork: Boolean = false,
    ): CommandResult {
        val networkSnapshot = if (allowNetwork) AndeeNetworkSnapshot.capture(context) else null
        val outputPipe = ParcelFileDescriptor.createPipe()
        val output = ByteArrayOutputStream()
        val truncated = AtomicBoolean(false)
        val streamFailure = AtomicReference<Throwable?>()
        val reader = thread(name = "AndockOutputCollector") {
            runCatching {
                ParcelFileDescriptor.AutoCloseInputStream(outputPipe[0]).use { source ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        val remaining = AndeeExecutionPolicy.MAX_OUTPUT_BYTES - output.size()
                        if (remaining > 0) output.write(buffer, 0, minOf(read, remaining))
                        if (read > remaining) truncated.set(true)
                    }
                    buffer.fill(0)
                }
            }.onFailure { streamFailure.compareAndSet(null, it) }
        }
        val inputPipe = input?.let { ParcelFileDescriptor.createPipe() }
        val writer = inputPipe?.let { pipe ->
            thread(name = "AndockInputWriter") {
                runCatching {
                    ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { destination ->
                        destination.write(input)
                    }
                }.onFailure { streamFailure.compareAndSet(null, it) }
            }
        }
        val networkBroker = networkSnapshot?.let { AndeeNetworkBroker(it.policy) }
        var status: JSONObject? = null
        var commandFailure: Throwable? = null
        try {
            try {
                status = storage.open(memberId).use { image ->
                    workers.execute(
                        memberId,
                        command,
                        cwd,
                        timeoutMs,
                        mergeError,
                        image,
                        inputPipe?.get(0),
                        outputPipe[1],
                        networkBroker,
                        networkSnapshot?.resolverConfiguration,
                    )
                }
            } catch (failure: Throwable) {
                commandFailure = failure
            } finally {
                networkBroker?.close()
                runCatching { outputPipe[1].close() }
                runCatching { inputPipe?.get(0)?.close() }
            }
            writer?.join()
            reader.join()
        } finally {
            outputPipe.forEach { runCatching { it.close() } }
            inputPipe?.forEach { runCatching { it.close() } }
        }
        streamFailure.get()?.let { failure ->
            commandFailure?.addSuppressed(failure) ?: throw failure
        }
        commandFailure?.let { throw it }
        return CommandResult(checkNotNull(status), output.toByteArray(), truncated.get())
    }

    private fun parseEntries(output: ByteArray): JSONArray {
        val entries = JSONArray()
        val fields = output.splitOnNull()
        if (fields.size % 4 != 0) {
            throw ExecutionFailure(500, "malformed-directory-listing")
        }
        fields.chunked(4).forEach { field ->
            val seconds = field[3].substringBefore('.').toLongOrNull() ?: 0L
            entries.put(
                JSONObject()
                    .put("name", field[0])
                    .put("type", findType(field[1]))
                    .put("size", field[2].toLongOrNull() ?: 0L)
                    .put(
                        "modified-at",
                        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochSecond(seconds)),
                    ),
            )
        }
        return entries
    }

    private fun ByteArray.splitOnNull(): List<String> {
        val fields = mutableListOf<String>()
        var start = 0
        for (index in indices) {
            if (this[index].toInt() != 0) continue
            fields.add(String(this, start, index - start, Charsets.UTF_8))
            start = index + 1
        }
        if (start != size) throw ExecutionFailure(500, "malformed-directory-listing")
        return fields
    }

    private fun findType(value: String): String = when (value) {
        "f" -> "file"
        "d" -> "directory"
        "l" -> "symlink"
        else -> "other"
    }

    private fun fileFailure(error: String): ExecutionFailure {
        val lower = error.lowercase()
        return when {
            "no such file or directory" in lower -> ExecutionFailure(404, "not-found")
            "is a directory" in lower -> ExecutionFailure(400, "path-is-directory")
            else -> ExecutionFailure(500, error.ifEmpty { "filesystem-operation-failed" })
        }
    }

    private fun validateMemberId(value: String): String {
        if (
            value.isEmpty() ||
            value.length > 256 ||
            value.any { !it.isLetterOrDigit() && it !in "_-" }
        ) {
            throw ExecutionFailure(400, "invalid-member-id")
        }
        return value
    }

    private fun <T> withMemberLock(memberId: String, block: () -> T): T {
        val entry = synchronized(locks) {
            locks.getOrPut(memberId, ::MemberLock).also { it.references++ }
        }
        return try {
            entry.lock.withLock(block)
        } finally {
            synchronized(locks) {
                entry.references--
                if (entry.references == 0 && locks[memberId] === entry) {
                    locks.remove(memberId)
                }
            }
        }
    }

    private fun normalizeGuestPath(value: String): String {
        require('\u0000' !in value) { "path-cannot-contain-null" }
        val absolute = if (value.startsWith('/')) value else "/root/$value"
        val parts = absolute.split('/').filter { it.isNotEmpty() && it != "." }
        if (".." in parts) throw ExecutionFailure(400, "path-cannot-contain-parent-segments")
        return if (parts.isEmpty()) "/" else "/${parts.joinToString("/")}"
    }

    private fun success(body: JSONObject): JSONObject =
        JSONObject().put("ok", true).put("status", 200).put("body", body)

    private fun failureResponse(failure: Throwable): JSONObject {
        val status = when (failure) {
            is ExecutionFailure -> failure.status
            is IllegalArgumentException, is JSONException -> 400
            else -> 500
        }
        if (status >= 500) {
            Log.w(TAG, "execution request failed", failure)
        } else {
            Log.i(TAG, "execution request rejected ($status): ${failure.message}")
        }
        return JSONObject()
            .put("ok", false)
            .put("status", status)
            .put("error", failure.message ?: failure.javaClass.simpleName)
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private fun decode(value: String): ByteArray =
        Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP)

    private fun shellQuote(value: String): String =
        "'${value.replace("'", "'\"'\"'")}'"

    private data class CommandResult(
        val status: JSONObject,
        val output: ByteArray,
        val truncated: Boolean,
    ) {
        fun error(): String {
            val encoded = status.optString("error")
            if (encoded.isEmpty()) return ""
            return runCatching {
                String(Base64.decode(encoded, Base64.URL_SAFE), Charsets.UTF_8).trim()
            }.getOrDefault(encoded)
        }
    }

    private class MemberLock {
        val lock = ReentrantLock()
        var references = 0
    }

    private companion object {
        const val TAG = "AndeeExecution"
        const val PROTOCOL = "andock-local@1"
        const val DEFAULT_TIMEOUT_MS = 15 * 60 * 1000
        const val READ_TIMEOUT_MS = 30 * 1000
        const val WRITE_TIMEOUT_MS = 30 * 1000
        const val LIST_TIMEOUT_MS = 30 * 1000
    }
}
