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
import java.security.MessageDigest
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
    private val sessions = mutableMapOf<String, BackgroundSession>()
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
        terminateAllSessions()
        workers.close()
    }

    private fun dispatch(request: JSONObject): JSONObject {
        check(running) { "execution manager is stopped" }
        require(request.optString("protocol") == PROTOCOL) { "unsupported-protocol" }
        val action = request.getString("action")
        val memberId = validateMemberId(request.getString("member-id"))
        if (action == "session-poll") return pollSession(memberId, request)
        if (action == "session-start") return startSession(memberId, request)
        if (action == "stop" || action == "destroy") {
            return withMemberCancellationFence(
                cancel = {
                    terminateMemberSessions(memberId)
                    workers.stop(memberId)
                },
                withLock = { block -> withMemberLock(memberId, block) },
            ) {
                if (action == "destroy") {
                    storage.destroy(memberId)
                    synchronized(sessions) {
                        sessions.entries.removeIf { it.value.memberId == memberId }
                    }
                }
                success(JSONObject())
            }
        }
        return withMemberLock(memberId) {
            when (action) {
                "read" -> withIdleMember(memberId) {
                    read(memberId, normalizeGuestPath(request.getString("path")))
                }
                "write" -> withIdleMember(memberId) {
                    write(
                        memberId,
                        normalizeGuestPath(request.getString("path")),
                        decode(request.getString("content")),
                    )
                }
                "list" -> withIdleMember(memberId) {
                    list(memberId, normalizeGuestPath(request.getString("path")))
                }
                "exec" -> withIdleMember(memberId) {
                    execute(
                        memberId,
                        normalizeGuestPath(request.optString("cwd", "/root")),
                        request.getString("command"),
                        request.optInt("timeout-ms", DEFAULT_TIMEOUT_MS)
                            .coerceIn(1, AndeeExecutionPolicy.MAX_TIMEOUT_MS),
                        request.optBoolean("allow-network", false),
                    )
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
            READ_TIMEOUT_MS.toLong(),
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
                WRITE_TIMEOUT_MS.toLong(),
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
            LIST_TIMEOUT_MS.toLong(),
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
            timeoutMs.toLong(),
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

    private fun startSession(memberId: String, request: JSONObject): JSONObject {
        val sessionId = validateSessionId(request.getString("session-id"))
        val cwd = normalizeGuestPath(request.optString("cwd", "/root"))
        val command = request.getString("command")
        require(command.isNotEmpty()) { "command-is-required" }
        val timeoutMs = if (request.isNull("timeout-ms")) {
            null
        } else {
            request.getLong("timeout-ms").also {
                require(it > 0) { "invalid-timeout" }
            }
        }
        val waitMs = request.optLong("wait-ms", DEFAULT_SESSION_WAIT_MS)
            .coerceIn(0, MAX_SESSION_WAIT_MS)
        val allowNetwork = request.optBoolean("allow-network", false)
        val key = sessionKey(memberId, sessionId)
        val session = withMemberLock(memberId) {
            synchronized(sessions) {
                cleanupSessionsLocked()
                sessions[key]?.also { existing ->
                    if (
                        existing.cwd != cwd ||
                        existing.command != command ||
                        existing.timeoutMs != timeoutMs ||
                        existing.allowNetwork != allowNetwork
                    ) {
                        throw ExecutionFailure(409, "session-id-conflict")
                    }
                } ?: run {
                    activeMemberSessionLocked(memberId)?.let { (active, status) ->
                        throw memberSessionActiveFailure(active, status)
                    }
                    BackgroundSession(
                        memberId,
                        sessionId,
                        cwd,
                        command,
                        timeoutMs,
                        allowNetwork,
                    ).also {
                        sessions[key] = it
                        launchSession(it)
                    }
                }
            }
        }
        return success(
            sessionResult(session, 0, waitMs, false, true)
                .put("command", command)
                .put("waited-ms", waitMs),
        )
    }

    private fun launchSession(session: BackgroundSession) {
        thread(name = "AndockSession-${session.sessionId.take(12)}") {
            try {
                val result = command(
                    session.memberId,
                    session.cwd,
                    "umask 022; ${session.command}",
                    session.timeoutMs ?: Long.MAX_VALUE,
                    true,
                    allowNetwork = session.allowNetwork,
                    onOutput = session::append,
                )
                session.finish(
                    when {
                        result.status.optBoolean("timed-out") -> "timed-out"
                        result.status.optBoolean("cancelled") -> "terminated"
                        else -> "exited"
                    },
                    when {
                        result.status.optBoolean("timed-out") -> 124
                        result.status.optBoolean("cancelled") -> 143
                        else -> result.status.optInt("exit-code")
                    },
                )
            } catch (_failure: Throwable) {
                session.finish("lost", null)
            }
        }
    }

    private fun pollSession(memberId: String, request: JSONObject): JSONObject {
        val sessionId = validateSessionId(request.getString("session-id"))
        val cursor = request.optLong("cursor", 0)
        if (cursor < 0 || cursor > Int.MAX_VALUE) {
            throw ExecutionFailure(400, "invalid-cursor")
        }
        val waitMs = request.optLong("wait-ms", DEFAULT_SESSION_WAIT_MS)
            .coerceIn(0, MAX_SESSION_WAIT_MS)
        val session = synchronized(sessions) {
            cleanupSessionsLocked()
            sessions[sessionKey(memberId, sessionId)]
        } ?: throw ExecutionFailure(404, "unknown-session")
        return success(
            sessionResult(
                session,
                cursor.toInt(),
                waitMs,
                request.optBoolean("terminate", false),
                false,
            ),
        )
    }

    private fun sessionResult(
        session: BackgroundSession,
        cursor: Int,
        waitMs: Long,
        terminate: Boolean,
        waitForTerminal: Boolean,
    ): JSONObject {
        if (terminate && session.requestTermination()) workers.stop(session.memberId)
        val snapshot = session.snapshot(cursor, waitMs, waitForTerminal)
        if (snapshot.invalidCursor) throw ExecutionFailure(400, "invalid-cursor")
        val result = JSONObject()
            .put("session-id", session.sessionId)
            .put("execution-status", snapshot.status)
            .put("cursor", cursor)
            .put("next-cursor", cursor + snapshot.output.size)
            .put("truncated", snapshot.hasMore)
            .put("output-limit-reached", snapshot.outputLimitReached)
            .put("output", encode(snapshot.output))
            .put("cwd", session.cwd)
            .put("command-sha256", session.commandSha256)
            .put("disable-network", !session.allowNetwork)
            .put("timeout-ms", session.timeoutMs ?: JSONObject.NULL)
        snapshot.exitCode?.let { result.put("exit-code", it) }
        return result
    }

    private fun terminateMemberSessions(memberId: String) {
        val owned = synchronized(sessions) {
            sessions.values.filter { it.memberId == memberId && it.requestTermination() }
        }
        if (owned.isNotEmpty()) workers.stop(memberId)
    }

    private fun terminateAllSessions() {
        val members = synchronized(sessions) {
            sessions.values
                .filter { it.requestTermination() }
                .map(BackgroundSession::memberId)
                .distinct()
        }
        members.forEach(workers::stop)
    }

    private fun cleanupSessionsLocked() {
        val cutoff = System.currentTimeMillis() - SESSION_RETENTION_MS
        sessions.entries.removeIf {
            !it.value.isRunning() && it.value.finishedAtMillis < cutoff
        }
        sessions.entries
            .filter { !it.value.isRunning() }
            .groupBy { it.value.memberId }
            .values
            .forEach { terminal ->
                terminal
                    .sortedByDescending { it.value.finishedAtMillis }
                    .drop(MAX_TERMINAL_SESSIONS)
                    .forEach { sessions.remove(it.key) }
            }
    }

    private fun validateSessionId(value: String): String {
        if (value.length !in 20..64 || value.any { !it.isLetterOrDigit() && it !in "_-" }) {
            throw ExecutionFailure(400, "invalid-session-id")
        }
        return value
    }

    private fun sessionKey(memberId: String, sessionId: String): String =
        "$memberId:$sessionId"

    private fun <T> withIdleMember(memberId: String, block: () -> T): T {
        synchronized(sessions) {
            cleanupSessionsLocked()
            activeMemberSessionLocked(memberId)?.let { (active, status) ->
                throw memberSessionActiveFailure(active, status)
            }
        }
        return block()
    }

    private fun activeMemberSessionLocked(memberId: String): Pair<BackgroundSession, String>? {
        sessions.values.forEach { session ->
            if (session.memberId == memberId) {
                session.runningStatus()?.let { return session to it }
            }
        }
        return null
    }

    private fun memberSessionActiveFailure(session: BackgroundSession, status: String) =
        ExecutionFailure(
            409,
            "member-session-active",
            memberSessionActiveDetails(session.sessionId, status),
            nonfatalWorkerContention = true,
        )

    private fun command(
        memberId: String,
        cwd: String,
        command: String,
        timeoutMs: Long,
        mergeError: Boolean,
        input: ByteArray? = null,
        allowNetwork: Boolean = false,
        onOutput: ((ByteArray, Int) -> Unit)? = null,
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
                        onOutput?.invoke(buffer, read)
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
            .also { response ->
                if (failure is ExecutionFailure) {
                    failure.details.forEach { (key, value) ->
                        response.put(
                            key,
                            if (value is Collection<*>) JSONArray(value) else value,
                        )
                    }
                }
            }
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

    private class BackgroundSession(
        val memberId: String,
        val sessionId: String,
        val cwd: String,
        val command: String,
        val timeoutMs: Long?,
        val allowNetwork: Boolean,
    ) {
        val commandSha256 = Base64.encodeToString(
            MessageDigest.getInstance("SHA-256").digest(command.toByteArray(Charsets.UTF_8)),
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        )
        private val monitor = Object()
        private val output = ByteArrayOutputStream()
        private var status = "running"
        private var exitCode: Int? = null
        private var outputLimitReached = false
        private var terminateRequested = false
        @Volatile var finishedAtMillis = Long.MAX_VALUE
            private set

        fun append(bytes: ByteArray, count: Int) = synchronized(monitor) {
            val remaining = MAX_SESSION_OUTPUT_BYTES - output.size()
            if (remaining > 0) output.write(bytes, 0, minOf(count, remaining))
            if (count > remaining) outputLimitReached = true
            monitor.notifyAll()
        }

        fun finish(nextStatus: String, code: Int?) = synchronized(monitor) {
            status = nextStatus
            exitCode = code
            finishedAtMillis = System.currentTimeMillis()
            monitor.notifyAll()
        }

        fun isRunning(): Boolean = synchronized(monitor) { status == "running" }

        fun runningStatus(): String? = synchronized(monitor) {
            status.takeIf { it == "running" }
        }

        fun requestTermination(): Boolean = synchronized(monitor) {
            if (status != "running" || terminateRequested) return@synchronized false
            terminateRequested = true
            true
        }

        fun snapshot(
            cursor: Int,
            waitMs: Long,
            waitForTerminal: Boolean,
        ): SessionSnapshot = synchronized(monitor) {
            if (cursor > output.size()) {
                return@synchronized SessionSnapshot.invalid()
            }
            val initialSize = output.size()
            val deadline = System.nanoTime() + waitMs * 1_000_000
            while (
                status == "running" &&
                    (waitForTerminal || output.size() == initialSize) &&
                    waitMs > 0
            ) {
                val remainingNanos = deadline - System.nanoTime()
                if (remainingNanos <= 0) break
                monitor.wait(
                    remainingNanos / 1_000_000,
                    (remainingNanos % 1_000_000).toInt(),
                )
            }
            val bytes = output.toByteArray()
            val end = minOf(bytes.size, cursor + MAX_SESSION_RESPONSE_BYTES)
            SessionSnapshot(
                status,
                exitCode,
                bytes.copyOfRange(cursor, end),
                end < bytes.size,
                outputLimitReached,
                false,
            )
        }
    }

    private data class SessionSnapshot(
        val status: String,
        val exitCode: Int?,
        val output: ByteArray,
        val hasMore: Boolean,
        val outputLimitReached: Boolean,
        val invalidCursor: Boolean,
    ) {
        companion object {
            fun invalid() = SessionSnapshot("running", null, byteArrayOf(), false, false, true)
        }
    }

    private companion object {
        const val TAG = "AndeeExecution"
        const val PROTOCOL = "andock-local@1"
        const val DEFAULT_TIMEOUT_MS = 15 * 60 * 1000
        const val READ_TIMEOUT_MS = 30 * 1000
        const val WRITE_TIMEOUT_MS = 30 * 1000
        const val LIST_TIMEOUT_MS = 30 * 1000
        const val DEFAULT_SESSION_WAIT_MS = 10_000L
        const val MAX_SESSION_WAIT_MS = 30_000L
        const val MAX_SESSION_RESPONSE_BYTES = 200_000
        const val MAX_SESSION_OUTPUT_BYTES = 2 * 1024 * 1024
        const val MAX_TERMINAL_SESSIONS = 32
        const val SESSION_RETENTION_MS = 24 * 60 * 60 * 1000L
    }
}

internal fun <T> withMemberCancellationFence(
    cancel: () -> Unit,
    withLock: ((() -> T) -> T),
    action: () -> T,
): T {
    cancel()
    return withLock {
        cancel()
        action()
    }
}

internal fun memberSessionActiveDetails(
    sessionId: String,
    executionStatus: String,
): Map<String, Any?> = mapOf(
    "session-id" to sessionId,
    "execution-status" to executionStatus,
    "session-control-action" to "bash-session",
    "session-control-operations" to listOf("poll", "wait", "terminate"),
    "retry-when" to "session-terminal",
)
