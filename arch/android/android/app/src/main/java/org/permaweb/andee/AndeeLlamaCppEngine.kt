package org.permaweb.andee

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Serialized, process-isolated GGUF runtime exposed only through an app-private socket. */
internal class AndeeLlamaCppEngine(private val context: Context) : AutoCloseable {
    private val generationLock = ReentrantLock(true)
    private val lifecycleLock = Any()
    private val executionExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "AndeeLlamaCppExecution").apply { isDaemon = true }
    }
    private val pending = ConcurrentHashMap.newKeySet<Future<*>>()
    private val closed = AtomicBoolean(false)
    @Volatile private var activeRuntime: LlamaRuntime? = null
    @Volatile private var activeSocket: LocalSocket? = null

    fun complete(
        model: AndeeInferenceModel,
        backendName: String,
        payload: JSONObject,
    ): JSONObject {
        val future = synchronized(lifecycleLock) {
            if (closed.get()) throw InferenceFailure(503, "inference-runtime-stopped")
            try {
                executionExecutor.submit<JSONObject> {
                    completeSerialized(model, backendName, payload)
                }.also(pending::add)
            } catch (_: RejectedExecutionException) {
                throw InferenceFailure(503, "inference-runtime-stopped")
            }
        }
        try {
            return future.get(
                AndeeInferencePolicy.GENERATION_TIMEOUT_MILLIS,
                TimeUnit.MILLISECONDS,
            )
        } catch (_: TimeoutException) {
            future.cancel(true)
            stopActiveRequest()
            throw InferenceFailure(408, "generation-timed-out")
        } catch (_: CancellationException) {
            throw InferenceFailure(503, "inference-runtime-stopped")
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            future.cancel(true)
            stopActiveRequest()
            throw InferenceFailure(503, "inference-request-interrupted")
        } catch (failure: ExecutionException) {
            throw failure.cause ?: failure
        } finally {
            pending.remove(future)
        }
    }

    fun isInitialized(model: AndeeInferenceModel, backendName: String): Boolean {
        val runtime = activeRuntime ?: return false
        return !closed.get() &&
            backendName == "cpu" &&
            runtime.key == LlamaKey(model.sha256, model.maxContextTokens) &&
            runtime.process.isAlive &&
            runtime.socket.exists()
    }

    fun releaseModel() {
        if (closed.get()) return
        generationLock.withLock {
            if (!closed.get()) releaseRuntime()
        }
    }

    override fun close() {
        synchronized(lifecycleLock) {
            if (!closed.compareAndSet(false, true)) return
            pending.forEach { it.cancel(true) }
            executionExecutor.shutdownNow()
        }
        stopActiveRequest()
        generationLock.withLock(::releaseRuntime)
    }

    private fun completeSerialized(
        model: AndeeInferenceModel,
        backendName: String,
        payload: JSONObject,
    ): JSONObject = generationLock.withLock {
        if (closed.get()) throw InferenceFailure(503, "inference-runtime-stopped")
        if (backendName != "cpu" || model.runtime != "llama-cpp") {
            throw InferenceFailure(400, "model-runtime-mismatch")
        }
        val prepared = prepareRequest(model, payload)
        val runtime = runtime(model)
        val response = httpRequest(
            runtime.socket,
            "POST",
            "/v1/chat/completions",
            prepared.body.toString(),
            REQUEST_TIMEOUT_MILLIS,
        )
        if (response.status !in 200..299) {
            val message = runCatching {
                JSONObject(response.body).optJSONObject("error")?.optString("message")
            }.getOrNull()?.takeIf(String::isNotBlank) ?: "llama-cpp-request-failed"
            throw InferenceFailure(
                if (response.status in 400..499) 400 else 502,
                message,
                mapOf("runtime" to "llama-cpp", "model" to model.id),
            )
        }
        normalizeResponse(model, prepared, JSONObject(response.body))
    }

    private fun runtime(model: AndeeInferenceModel): LlamaRuntime {
        val key = LlamaKey(model.sha256, model.maxContextTokens)
        activeRuntime?.takeIf { it.key == key && it.process.isAlive }?.let { return it }
        releaseRuntime()
        val nativeRoot = File(context.applicationInfo.nativeLibraryDir)
        val executable = File(nativeRoot, LLAMA_SERVER)
        if (!executable.isFile || !executable.canExecute()) {
            throw InferenceFailure(503, "llama-cpp-runtime-missing")
        }
        val socket = AndeePaths.llamaCppSocketFile(context)
        socket.delete()
        val logs = AndeePaths.llamaCppLogRoot(context).also(File::mkdirs)
        val process = ProcessBuilder(
            executable.absolutePath,
            "--model", model.file.absolutePath,
            "--alias", model.id,
            "--host", socket.absolutePath,
            "--ctx-size", model.maxContextTokens.toString(),
            "--parallel", "1",
            "--no-cont-batching",
            "--no-webui",
            "--no-slots",
            "--no-mmproj",
            "--jinja",
            "--reasoning", "off",
            "--threads", GENERATION_THREADS.toString(),
            "--threads-batch", BATCH_THREADS.toString(),
            "--batch-size", BATCH_TOKENS.toString(),
            "--ubatch-size", UBATCH_TOKENS.toString(),
            "--threads-http", "1",
            "--timeout", SERVER_TIMEOUT_SECONDS.toString(),
        )
            .directory(nativeRoot)
            .redirectOutput(File(logs, "server.stdout"))
            .redirectError(File(logs, "server.stderr"))
            .apply {
                environment()["LD_LIBRARY_PATH"] = nativeRoot.absolutePath
            }
            .start()
        val created = LlamaRuntime(key, process, socket)
        activeRuntime = created
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(STARTUP_TIMEOUT_MILLIS)
        while (System.nanoTime() < deadline) {
            if (closed.get() || Thread.currentThread().isInterrupted) {
                releaseRuntime()
                throw InferenceFailure(503, "inference-runtime-stopped")
            }
            if (!process.isAlive) {
                val exit = runCatching { process.exitValue() }.getOrDefault(-1)
                releaseRuntime()
                throw InferenceFailure(
                    503,
                    "llama-cpp-initialization-failed",
                    mapOf("model" to model.id, "exit-status" to exit),
                )
            }
            if (socket.exists()) {
                val health = runCatching {
                    httpRequest(socket, "GET", "/health", null, HEALTH_TIMEOUT_MILLIS)
                }.getOrNull()
                if (health?.status == 200) {
                    Log.i(
                        TAG,
                        "llama.cpp initialized model=${model.id} build=${BuildConfig.LLAMA_CPP_VERSION}",
                    )
                    return created
                }
            }
            Thread.sleep(STARTUP_POLL_MILLIS)
        }
        releaseRuntime()
        throw InferenceFailure(503, "llama-cpp-initialization-timed-out")
    }

    private fun prepareRequest(
        model: AndeeInferenceModel,
        payload: JSONObject,
    ): PreparedRequest {
        if (payload.optBoolean("stream", false)) {
            throw InferenceFailure(400, "streaming-is-not-supported")
        }
        if (payload.optBoolean("tee", false)) {
            throw InferenceFailure(400, "tee-attestation-is-not-supported")
        }
        if (payload.has("stop") && !payload.isNull("stop")) {
            throw InferenceFailure(400, "stop-sequences-are-not-supported")
        }
        mapOf(
            "reasoning" to "reasoning-is-not-supported",
            "reasoning_effort" to "reasoning-effort-is-not-supported",
            "thinking" to "thinking-is-not-supported",
            "presence_penalty" to "presence-penalty-is-not-supported",
            "frequency_penalty" to "frequency-penalty-is-not-supported",
            "logit_bias" to "logit-bias-is-not-supported",
            "repetition_penalty" to "repetition-penalty-is-not-supported",
            "length_penalty" to "length-penalty-is-not-supported",
            "early_stopping" to "early-stopping-is-not-supported",
        ).forEach { (key, error) ->
            if (payload.has(key) && !payload.isNull(key)) {
                throw InferenceFailure(400, error)
            }
        }
        if (payload.optInt("n", 1) != 1) {
            throw InferenceFailure(400, "only-one-completion-is-supported")
        }
        val messages = payload.optJSONArray("messages")
            ?: throw InferenceFailure(400, "messages-must-be-an-array")
        if (messages.length() !in 1..AndeeInferencePolicy.MAX_MESSAGES) {
            throw InferenceFailure(400, "messages-must-not-be-empty")
        }
        for (index in 0 until messages.length()) {
            val message = messages.getJSONObject(index)
            if (message.getString("role") !in MESSAGE_ROLES) {
                throw InferenceFailure(400, "unsupported-message-role")
            }
            if (message.toString().toByteArray(Charsets.UTF_8).size >
                AndeeInferencePolicy.MAX_TEXT_BYTES
            ) {
                throw InferenceFailure(413, "message-too-large")
            }
        }
        val rawTools = payload.optJSONArray("tools")
        if (payload.has("tools") && rawTools == null) {
            throw InferenceFailure(400, "tools-must-be-an-array")
        }
        if ((rawTools?.length() ?: 0) > AndeeInferencePolicy.MAX_TOOLS) {
            throw InferenceFailure(413, "too-many-tools")
        }
        val supplied = mutableSetOf<String>()
        rawTools?.let { tools ->
            for (index in 0 until tools.length()) {
                val tool = tools.getJSONObject(index)
                if (tool.optString("type", "function") != "function") {
                    throw InferenceFailure(400, "unsupported-tool-type")
                }
                val name = tool.getJSONObject("function").getString("name")
                if (name.isBlank()) throw InferenceFailure(400, "tool-name-is-required")
                if (!supplied.add(name)) throw InferenceFailure(400, "duplicate-tool-name")
            }
        }
        val choice = parseToolChoice(payload)
        val allowed = allowedToolNames(choice, supplied)
        if (choice == AndeeToolChoice.Required && allowed.isEmpty()) {
            throw InferenceFailure(400, "tool-choice-requires-tools")
        }
        val maximum = when {
            payload.has("max_completion_tokens") -> payload.getInt("max_completion_tokens")
            payload.has("max_tokens") -> payload.getInt("max_tokens")
            else -> model.maxOutputTokens
        }
        if (maximum !in 1..model.maxOutputTokens) {
            throw InferenceFailure(
                400,
                "invalid-max-output-tokens",
                mapOf("maximum" to model.maxOutputTokens),
            )
        }
        val body = JSONObject(payload.toString())
            .put("model", model.id)
            .put("stream", false)
            .put("max_tokens", maximum)
        body.remove("max_completion_tokens")
        when (choice) {
            AndeeToolChoice.Auto -> body.put("tool_choice", "auto")
            AndeeToolChoice.None -> body.put("tool_choice", "none")
            AndeeToolChoice.Required -> body.put("tool_choice", "required")
            is AndeeToolChoice.Named -> {
                val selected = JSONArray()
                rawTools?.let { tools ->
                    for (index in 0 until tools.length()) {
                        val tool = tools.getJSONObject(index)
                        if (tool.getJSONObject("function").getString("name") == choice.name) {
                            selected.put(JSONObject(tool.toString()))
                        }
                    }
                }
                body.put("tools", selected)
                body.put("tool_choice", "required")
            }
        }
        return PreparedRequest(body, choice, allowed)
    }

    private fun normalizeResponse(
        model: AndeeInferenceModel,
        prepared: PreparedRequest,
        response: JSONObject,
    ): JSONObject {
        val choices = response.optJSONArray("choices")
            ?: throw InferenceFailure(502, "invalid-llama-cpp-response")
        if (choices.length() != 1) throw InferenceFailure(502, "invalid-llama-cpp-response")
        val choice = choices.getJSONObject(0)
        val finishReason = choice.optString("finish_reason")
        if (finishReason !in FINISH_REASONS) {
            throw InferenceFailure(502, "invalid-finish-reason")
        }
        val message = choice.getJSONObject("message")
        val returned = mutableListOf<String>()
        message.optJSONArray("tool_calls")?.let { calls ->
            for (index in 0 until calls.length()) {
                val call = calls.getJSONObject(index)
                if (call.optString("type", "function") != "function") {
                    throw InferenceFailure(502, "invalid-tool-call")
                }
                val function = call.getJSONObject("function")
                returned += function.getString("name")
                val arguments = function.getString("arguments")
                try {
                    JSONObject(arguments)
                } catch (_: Exception) {
                    throw InferenceFailure(502, "invalid-tool-call-arguments")
                }
                if (call.optString("id").isBlank()) {
                    throw InferenceFailure(502, "missing-tool-call-id")
                }
            }
        }
        val content = message.optString("content", "")
        if (returned.isEmpty() && PARTIAL_TOOL_MARKERS.any(content::contains)) {
            throw InferenceFailure(502, "partial-tool-call")
        }
        validateToolCalls(
            prepared.toolChoice,
            prepared.allowedTools,
            returned,
            truncated = finishReason == "length",
        )
        if (returned.isNotEmpty() && finishReason != "tool_calls") {
            throw InferenceFailure(502, "invalid-tool-finish-reason")
        }
        message.optString("reasoning_content").takeIf(String::isNotBlank)?.let {
            message.put("reasoning", it)
        }
        response.put("model", model.id)
        response.put(
            "andee-execution",
            JSONObject()
                .put("requested-backend", "cpu")
                .put("runtime", "llama-cpp")
                .put("runtime-version", BuildConfig.LLAMA_CPP_VERSION)
                .put("runtime-commit", BuildConfig.LLAMA_CPP_COMMIT)
                .put("runtime-initialized", true)
                .put("npu-execution-verified", false)
                .put("model-sha256", model.sha256)
                .put("model-bytes", model.file.length())
                .put("physical-memory-bytes", androidPhysicalMemoryBytes())
                .put("reserved-memory-bytes", LLAMA_CPP_MEMORY_HEADROOM_BYTES)
                .put("soc-model", currentSocModel()),
        )
        return response
    }

    private fun parseToolChoice(payload: JSONObject): AndeeToolChoice {
        if (!payload.has("tool_choice") || payload.isNull("tool_choice")) {
            return AndeeToolChoice.Auto
        }
        return when (val choice = payload.get("tool_choice")) {
            "auto" -> AndeeToolChoice.Auto
            "none" -> AndeeToolChoice.None
            "required" -> AndeeToolChoice.Required
            is JSONObject -> {
                if (choice.optString("type", "function") != "function") {
                    throw InferenceFailure(400, "unsupported-tool-choice")
                }
                val name = choice.optJSONObject("function")
                    ?.optString("name")
                    ?.takeIf(String::isNotBlank)
                    ?: throw InferenceFailure(400, "unsupported-tool-choice")
                AndeeToolChoice.Named(name)
            }
            else -> throw InferenceFailure(400, "unsupported-tool-choice")
        }
    }

    private fun httpRequest(
        socketFile: File,
        method: String,
        path: String,
        body: String?,
        timeoutMillis: Int,
    ): HttpResponse {
        val socket = LocalSocket()
        activeSocket = socket
        try {
            socket.connect(
                LocalSocketAddress(socketFile.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM),
            )
            socket.soTimeout = timeoutMillis
            val payload = body?.toByteArray(StandardCharsets.UTF_8) ?: ByteArray(0)
            val headers = buildString {
                append(method).append(' ').append(path).append(" HTTP/1.1\r\n")
                append("Host: localhost\r\n")
                append("Accept: application/json\r\n")
                append("Connection: close\r\n")
                if (body != null) {
                    append("Content-Type: application/json\r\n")
                    append("Content-Length: ").append(payload.size).append("\r\n")
                }
                append("\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            socket.outputStream.apply {
                write(headers)
                if (payload.isNotEmpty()) write(payload)
                flush()
            }
            return readResponse(BufferedInputStream(socket.inputStream))
        } finally {
            if (activeSocket === socket) activeSocket = null
            runCatching(socket::close)
        }
    }

    private fun readResponse(input: BufferedInputStream): HttpResponse {
        val statusLine = readLine(input)
        val status = statusLine.split(' ').getOrNull(1)?.toIntOrNull()
            ?: throw InferenceFailure(502, "invalid-llama-cpp-http-status")
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = readLine(input)
            if (line.isEmpty()) break
            val split = line.indexOf(':')
            if (split <= 0) throw InferenceFailure(502, "invalid-llama-cpp-http-header")
            headers[line.substring(0, split).lowercase(Locale.US)] =
                line.substring(split + 1).trim()
        }
        val bytes = when {
            headers["transfer-encoding"]?.equals("chunked", ignoreCase = true) == true ->
                readChunked(input)
            headers["content-length"] != null -> {
                val length = headers.getValue("content-length").toIntOrNull()
                    ?: throw InferenceFailure(502, "invalid-llama-cpp-content-length")
                if (length !in 0..AndeeInferencePolicy.MAX_FRAME_BYTES) {
                    throw InferenceFailure(502, "llama-cpp-response-too-large")
                }
                readExact(input, length)
            }
            else -> readToEnd(input)
        }
        return HttpResponse(status, bytes.toString(StandardCharsets.UTF_8))
    }

    private fun readLine(input: InputStream): String {
        val bytes = ByteArrayOutputStream()
        while (bytes.size() <= MAX_HTTP_LINE_BYTES) {
            val value = input.read()
            if (value < 0) throw EOFException("unexpected end of HTTP response")
            if (value == '\n'.code) break
            if (value != '\r'.code) bytes.write(value)
        }
        if (bytes.size() > MAX_HTTP_LINE_BYTES) {
            throw InferenceFailure(502, "llama-cpp-http-line-too-large")
        }
        return bytes.toString(StandardCharsets.US_ASCII.name())
    }

    private fun readExact(input: InputStream, length: Int): ByteArray {
        val result = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(result, offset, length - offset)
            if (count < 0) throw EOFException("truncated HTTP response")
            offset += count
        }
        return result
    }

    private fun readChunked(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        while (true) {
            val length = readLine(input).substringBefore(';').toIntOrNull(16)
                ?: throw InferenceFailure(502, "invalid-llama-cpp-http-chunk")
            if (length == 0) {
                while (readLine(input).isNotEmpty()) Unit
                break
            }
            if (output.size() + length > AndeeInferencePolicy.MAX_FRAME_BYTES) {
                throw InferenceFailure(502, "llama-cpp-response-too-large")
            }
            output.write(readExact(input, length))
            if (readLine(input).isNotEmpty()) {
                throw InferenceFailure(502, "invalid-llama-cpp-http-chunk")
            }
        }
        return output.toByteArray()
    }

    private fun readToEnd(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size() + count > AndeeInferencePolicy.MAX_FRAME_BYTES) {
                throw InferenceFailure(502, "llama-cpp-response-too-large")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun stopActiveRequest() {
        runCatching { activeSocket?.close() }
        activeRuntime?.process?.let(::stopProcess)
    }

    private fun releaseRuntime() {
        val runtime = activeRuntime ?: return
        activeRuntime = null
        runCatching { activeSocket?.close() }
        stopProcess(runtime.process)
        runtime.socket.delete()
    }

    private fun stopProcess(process: Process) {
        if (!process.isAlive) return
        process.destroy()
        if (!runCatching { process.waitFor(PROCESS_STOP_MILLIS, TimeUnit.MILLISECONDS) }
                .getOrDefault(false)
        ) {
            process.destroyForcibly()
            runCatching { process.waitFor(PROCESS_KILL_MILLIS, TimeUnit.MILLISECONDS) }
        }
    }

    private data class LlamaKey(val modelSha256: String, val maxContextTokens: Int)
    private data class LlamaRuntime(val key: LlamaKey, val process: Process, val socket: File)
    private data class PreparedRequest(
        val body: JSONObject,
        val toolChoice: AndeeToolChoice,
        val allowedTools: Set<String>,
    )
    private data class HttpResponse(val status: Int, val body: String)

    private companion object {
        const val TAG = "AndeeInference"
        const val LLAMA_SERVER = "libandee_llama_server.so"
        const val GENERATION_THREADS = 4
        const val BATCH_THREADS = 8
        const val BATCH_TOKENS = 512
        const val UBATCH_TOKENS = 128
        const val SERVER_TIMEOUT_SECONDS = 570
        const val STARTUP_TIMEOUT_MILLIS = 540_000L
        const val REQUEST_TIMEOUT_MILLIS = 570_000
        const val HEALTH_TIMEOUT_MILLIS = 1_000
        const val STARTUP_POLL_MILLIS = 250L
        const val PROCESS_STOP_MILLIS = 5_000L
        const val PROCESS_KILL_MILLIS = 5_000L
        const val MAX_HTTP_LINE_BYTES = 16 * 1024
        val MESSAGE_ROLES = setOf("system", "user", "assistant", "tool")
        val FINISH_REASONS = setOf("stop", "tool_calls", "length")
        val PARTIAL_TOOL_MARKERS = listOf("<tool_call", "<function=", "<parameter=")
    }
}
