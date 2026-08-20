package org.permaweb.andee

import android.content.Context
import android.util.Base64
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.OpenApiTool
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ToolCall
import com.google.ai.edge.litertlm.ToolProvider
import com.google.ai.edge.litertlm.tool
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
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

/** Serialized LiteRT-LM engine owner with bounded generation and explicit backend requests. */
@OptIn(ExperimentalApi::class)
internal class AndeeInferenceEngine(private val context: Context) : AutoCloseable {
    private val generationLock = ReentrantLock(true)
    private val conversationLock = ReentrantLock(true)
    private val lifecycleLock = Any()
    private val executionExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "AndeeInferenceExecution").apply { isDaemon = true }
    }
    private val pending = ConcurrentHashMap.newKeySet<Future<*>>()
    private val closed = AtomicBoolean(false)
    private val hardResetScheduled = AtomicBoolean(false)
    @Volatile private var activeKey: EngineKey? = null
    @Volatile private var activeEngine: Engine? = null
    @Volatile private var activeConversation: Conversation? = null

    init {
        acquireOwner()
        ExperimentalFlags.enableBenchmark = true
    }

    fun complete(
        model: AndeeInferenceModel,
        backendName: String,
        payload: JSONObject,
    ): JSONObject {
        val expired = AtomicBoolean(false)
        val future = synchronized(lifecycleLock) {
            if (closed.get()) throw InferenceFailure(503, "inference-runtime-stopped")
            try {
                executionExecutor.submit<JSONObject> {
                    completeSerialized(model, backendName, payload, expired)
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
            expired.set(true)
            future.cancel(true)
            cancelActiveConversationAsync()
            scheduleHardReset("inference deadline exceeded", TIMEOUT_RESET_DELAY_MILLIS)
            throw InferenceFailure(408, "generation-timed-out")
        } catch (_: CancellationException) {
            throw InferenceFailure(503, "inference-runtime-stopped")
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            expired.set(true)
            future.cancel(true)
            cancelActiveConversationAsync()
            throw InferenceFailure(503, "inference-request-interrupted")
        } catch (failure: ExecutionException) {
            throw failure.cause ?: failure
        } finally {
            pending.remove(future)
        }
    }

    private fun completeSerialized(
        model: AndeeInferenceModel,
        backendName: String,
        payload: JSONObject,
        expired: AtomicBoolean,
    ): JSONObject = generationLock.withLock {
        if (closed.get()) throw InferenceFailure(503, "inference-runtime-stopped")
        if (expired.get()) throw InferenceFailure(408, "generation-timed-out")
        val input = conversationInput(payload)
        rejectUnsupportedFeatures(payload)
        val rawTools = payload.optJSONArray("tools")
        if (payload.has("tools") && rawTools == null) {
            throw InferenceFailure(400, "tools-must-be-an-array")
        }
        val choice = toolChoice(payload)
        val bindings = tools(rawTools)
        val allowedNames = allowedToolNames(choice, bindings.map(ToolBinding::name).toSet())
        if (choice == AndeeToolChoice.Required && allowedNames.isEmpty()) {
            throw InferenceFailure(400, "tool-choice-requires-tools")
        }
        val selectedTools = bindings
            .filter { it.name in allowedNames }
            .map(ToolBinding::provider)
        val sampler = sampler(payload)
        val maxOutputTokens = outputTokens(payload, model)
        val config = ConversationConfig(
            initialMessages = requiredToolInstruction(choice)?.let { listOf(Message.system(it)) }
                .orEmpty() + input.initialMessages,
            tools = selectedTools,
            samplerConfig = sampler,
            automaticToolCalling = false,
            maxOutputToken = maxOutputTokens,
        )
        val engine = engine(model, backendName)
        if (expired.get()) throw InferenceFailure(408, "generation-timed-out")
        val conversation = engine.createConversation(config)
        conversationLock.withLock {
            if (closed.get() || expired.get()) {
                conversation.close()
                throw InferenceFailure(
                    if (expired.get()) 408 else 503,
                    if (expired.get()) "generation-timed-out" else "inference-runtime-stopped",
                )
            }
            activeConversation = conversation
        }
        try {
            val response = conversation.sendMessage(input.turn)
            if (expired.get()) throw InferenceFailure(408, "generation-timed-out")
            val finishReason = inferenceFinishReason(
                response.toolCalls.isNotEmpty(),
                conversation.getBenchmarkInfo().lastDecodeTokenCount,
                maxOutputTokens,
            )
            validateToolCalls(
                choice,
                allowedNames,
                response.toolCalls.map(ToolCall::name),
                truncated = finishReason == "length",
            )
            completionResponse(model, backendName, response, finishReason)
        } catch (failure: Throwable) {
            if (expired.get()) throw InferenceFailure(408, "generation-timed-out")
            throw failure
        } finally {
            conversationLock.withLock {
                if (activeConversation === conversation) activeConversation = null
                conversation.close()
            }
        }
    }

    fun isInitialized(model: AndeeInferenceModel, backendName: String): Boolean =
        !closed.get() && activeKey == EngineKey(
            model.sha256,
            backendName,
            model.maxContextTokens,
        )

    fun releaseModel() {
        if (closed.get()) return
        generationLock.withLock {
            if (!closed.get()) releaseEngine()
        }
    }

    override fun close() {
        synchronized(lifecycleLock) {
            if (!closed.compareAndSet(false, true)) return
            pending.forEach { it.cancel(true) }
            executionExecutor.shutdownNow()
        }
        val resetCancellation = scheduleHardReset(
            "inference shutdown did not quiesce",
            SHUTDOWN_RESET_DELAY_MILLIS,
        )
        Thread(
            {
                try {
                    cancelActiveConversation()
                    generationLock.withLock {
                        releaseEngine()
                    }
                    resetCancellation?.set(true)
                    OWNER.set(false)
                } catch (failure: Throwable) {
                    Log.e(
                        TAG,
                        "inference shutdown failed; process reset remains armed",
                        failure,
                    )
                }
            },
            "AndeeInferenceShutdown",
        ).apply { isDaemon = true }.start()
    }

    private fun cancelActiveConversationAsync() {
        Thread(::cancelActiveConversation, "AndeeInferenceCancel")
            .apply { isDaemon = true }
            .start()
    }

    private fun cancelActiveConversation() {
        conversationLock.withLock {
            activeConversation?.let { conversation ->
                runCatching { conversation.cancelProcess() }
            }
        }
    }

    private fun scheduleHardReset(reason: String, delayMillis: Long): AtomicBoolean? {
        if (!hardResetScheduled.compareAndSet(false, true)) return null
        val cancelled = AtomicBoolean(false)
        Log.e(TAG, "$reason; scheduling AndEE process reset")
        Thread(
            {
                try {
                    Thread.sleep(delayMillis)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                if (cancelled.get()) return@Thread
                runCatching { HyperbeamRuntime.killResidualRuntimeProcesses(context) }
                android.os.Process.killProcess(android.os.Process.myPid())
            },
            "AndeeInferenceHardReset",
        ).apply { isDaemon = true }.start()
        return cancelled
    }

    private fun acquireOwner() {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(OWNER_WAIT_MILLIS)
        while (!OWNER.compareAndSet(false, true)) {
            if (System.nanoTime() >= deadline) {
                throw IllegalStateException("inference runtime did not finish shutting down")
            }
            try {
                Thread.sleep(OWNER_RETRY_MILLIS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IllegalStateException("interrupted while waiting for inference shutdown")
            }
        }
    }

    private fun releaseEngine() {
        val engine = activeEngine
        if (engine?.isInitialized() == true) engine.close()
        activeEngine = null
        activeKey = null
    }

    private fun engine(model: AndeeInferenceModel, backendName: String): Engine {
        if (closed.get()) throw InferenceFailure(503, "inference-runtime-stopped")
        val key = EngineKey(model.sha256, backendName, model.maxContextTokens)
        if (activeKey == key) return checkNotNull(activeEngine)
        releaseEngine()
        val backend = when (backendName) {
            "cpu" -> Backend.CPU(threadCount = 2)
            "gpu" -> Backend.GPU()
            "npu" -> {
                try {
                    System.loadLibrary(GOOGLE_TENSOR_SOUTHBOUND_LIBRARY)
                } catch (failure: UnsatisfiedLinkError) {
                    Log.e(TAG, "Google Tensor southbound runtime could not be loaded", failure)
                    throw InferenceFailure(503, "npu-southbound-runtime-unavailable")
                }
                Backend.NPU(context.applicationInfo.nativeLibraryDir)
            }
            else -> throw InferenceFailure(400, "unsupported-backend")
        }
        val created = Engine(
            EngineConfig(
                modelPath = model.file.absolutePath,
                backend = backend,
                maxNumTokens = model.maxContextTokens,
                cacheDir = AndeePaths.inferenceCacheRoot(context).absolutePath,
            ),
        )
        try {
            created.initialize()
        } catch (failure: Throwable) {
            if (created.isInitialized()) {
                try {
                    created.close()
                } catch (cleanupFailure: Throwable) {
                    failure.addSuppressed(cleanupFailure)
                }
            }
            Log.e(TAG, "LiteRT-LM initialization failed for ${model.id}/$backendName", failure)
            throw InferenceFailure(
                503,
                "backend-initialization-failed",
                mapOf("backend" to backendName, "model" to model.id),
            )
        }
        activeKey = key
        activeEngine = created
        Log.i(TAG, "LiteRT-LM initialized model=${model.id} backend=$backendName")
        return created
    }

    private fun conversationInput(payload: JSONObject): ConversationInput {
        val raw = payload.optJSONArray("messages")
        if (payload.has("messages") && raw == null) {
            throw InferenceFailure(400, "messages-must-be-an-array")
        }
        if (raw == null) {
            val prompt = payload.opt("prompt") as? String
                ?: throw InferenceFailure(400, "messages-or-prompt-is-required")
            checkTextSize(prompt)
            return ConversationInput(emptyList(), Message.user(prompt))
        }
        if (raw.length() == 0) throw InferenceFailure(400, "messages-must-not-be-empty")
        if (raw.length() > AndeeInferencePolicy.MAX_MESSAGES) {
            throw InferenceFailure(413, "too-many-messages")
        }
        val toolNames = mutableMapOf<String, String>()
        val parsed = (0 until raw.length()).map { index ->
            val item = raw.getJSONObject(index)
            val role = item.getString("role")
            val text = textContent(item.opt("content"))
            checkTextSize(text)
            when (role) {
                "system" -> Message.system(text)
                "user" -> Message.user(text)
                "assistant" -> {
                    val calls = item.optJSONArray("tool_calls")?.let { values ->
                        (0 until values.length()).map { callIndex ->
                            val call = values.getJSONObject(callIndex)
                            val function = call.getJSONObject("function")
                            val name = function.getString("name")
                            call.optString("id").takeIf(String::isNotBlank)?.let {
                                toolNames[it] = name
                            }
                            val arguments = try {
                                JSONObject(function.optString("arguments", "{}"))
                            } catch (_: Exception) {
                                throw InferenceFailure(400, "invalid-tool-arguments")
                            }
                            ToolCall(name, jsonMap(arguments))
                        }
                    }.orEmpty()
                    Message.model(
                        Contents.of(text),
                        calls,
                        assistantChannels(item),
                    )
                }
                "tool" -> {
                    val name = item.optString("name").takeIf(String::isNotBlank)
                        ?: toolNames[item.optString("tool_call_id")]
                        ?: throw InferenceFailure(400, "tool-name-is-required")
                    Message.tool(Contents.of(Content.ToolResponse(name, jsonValue(text))))
                }
                else -> throw InferenceFailure(400, "unsupported-message-role")
            }.let { role to it }
        }
        val (lastRole, turn) = parsed.last()
        if (lastRole !in setOf("user", "tool")) {
            throw InferenceFailure(400, "conversation-must-end-with-user-or-tool")
        }
        return ConversationInput(parsed.dropLast(1).map { it.second }, turn)
    }

    private fun tools(raw: JSONArray?): List<ToolBinding> {
        if (raw == null) return emptyList()
        if (raw.length() > AndeeInferencePolicy.MAX_TOOLS) {
            throw InferenceFailure(413, "too-many-tools")
        }
        return (0 until raw.length()).map { index ->
            val entry = raw.getJSONObject(index)
            if (entry.optString("type", "function") != "function") {
                throw InferenceFailure(400, "unsupported-tool-type")
            }
            val function = entry.getJSONObject("function")
            val name = function.optString("name").takeIf(String::isNotBlank)
                ?: throw InferenceFailure(400, "tool-name-is-required")
            val description = JSONObject(function.toString())
            object : OpenApiTool {
                override fun getToolDescriptionJsonString(): String = description.toString()
                override fun execute(paramsJsonString: String): String {
                    throw IllegalStateException("automatic tool execution is disabled")
                }
            }.let(::tool).let { ToolBinding(name, it) }
        }.also { bindings ->
            if (bindings.map(ToolBinding::name).distinct().size != bindings.size) {
                throw InferenceFailure(400, "duplicate-tool-name")
            }
        }
    }

    private fun sampler(payload: JSONObject): SamplerConfig? {
        if (
            !payload.has("top_k") &&
            !payload.has("top_p") &&
            !payload.has("temperature") &&
            !payload.has("seed")
        ) return null
        val topK = payload.optInt("top_k", 64)
        val topP = payload.optDouble("top_p", 0.95)
        val temperature = payload.optDouble("temperature", 1.0)
        if (topK < 1) throw InferenceFailure(400, "invalid-top-k")
        if (topP !in 0.0..1.0) throw InferenceFailure(400, "invalid-top-p")
        if (temperature < 0.0) throw InferenceFailure(400, "invalid-temperature")
        return SamplerConfig(
            topK = topK,
            topP = topP,
            temperature = temperature,
            seed = payload.optInt("seed", 0),
        )
    }

    private fun outputTokens(payload: JSONObject, model: AndeeInferenceModel): Int {
        if (payload.optInt("n", 1) != 1) {
            throw InferenceFailure(400, "only-one-completion-is-supported")
        }
        val requested = when {
            payload.has("max_completion_tokens") -> payload.getInt("max_completion_tokens")
            payload.has("max_tokens") -> payload.getInt("max_tokens")
            else -> model.maxOutputTokens
        }
        if (requested !in 1..model.maxOutputTokens) {
            throw InferenceFailure(
                400,
                "invalid-max-output-tokens",
                mapOf("maximum" to model.maxOutputTokens),
            )
        }
        return requested
    }

    private fun toolChoice(payload: JSONObject): AndeeToolChoice {
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

    private fun requiredToolInstruction(choice: AndeeToolChoice): String? {
        val name = when (choice) {
            AndeeToolChoice.Required -> "one of the supplied functions"
            is AndeeToolChoice.Named -> choice.name
            else -> return null
        }
        return "This request requires a function call. Call $name and do not answer with plain text."
    }

    private fun rejectUnsupportedFeatures(payload: JSONObject) {
        if (payload.optBoolean("stream", false)) {
            throw InferenceFailure(400, "streaming-is-not-supported")
        }
        if (payload.has("stop") && !payload.isNull("stop")) {
            throw InferenceFailure(400, "stop-sequences-are-not-supported")
        }
        if (payload.optBoolean("tee", false)) {
            throw InferenceFailure(400, "tee-attestation-is-not-supported")
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
    }

    private fun completionResponse(
        model: AndeeInferenceModel,
        backend: String,
        response: Message,
        finishReason: String,
    ): JSONObject {
        val toolCalls = JSONArray()
        response.toolCalls.forEachIndexed { index, call ->
            toolCalls.put(
                JSONObject()
                    .put("id", callId(model.id, call, index))
                    .put("type", "function")
                    .put(
                        "function",
                        JSONObject()
                            .put("name", call.name)
                            .put("arguments", JSONObject(call.arguments).toString()),
                    ),
            )
        }
        val message = JSONObject()
            .put("role", "assistant")
            .put("content", response.toString())
        if (toolCalls.length() > 0) message.put("tool_calls", toolCalls)
        if (response.channels.isNotEmpty()) {
            message.put("reasoning", response.channels.values.joinToString("\n"))
            message.put("reasoning_details", JSONObject(response.channels))
        }
        return JSONObject()
            .put("id", completionId(model.id, response.toString()))
            .put("object", "chat.completion")
            .put("model", model.id)
            .put(
                "choices",
                JSONArray().put(
                    JSONObject()
                        .put("index", 0)
                        .put("message", message)
                        .put("finish_reason", finishReason),
                ),
            )
            .put(
                "andee-execution",
                JSONObject()
                    .put("requested-backend", backend)
                    .put("runtime", "litert-lm")
                    .put("runtime-initialized", true)
                    .put("npu-execution-verified", false)
                    .put("model-sha256", model.sha256)
                    .put("soc-model", currentSocModel()),
            )
    }

    private fun textContent(value: Any?): String = when (value) {
        null, JSONObject.NULL -> ""
        is String -> value
        is JSONArray -> (0 until value.length()).joinToString("") { index ->
            val part = value.getJSONObject(index)
            if (part.optString("type") != "text") {
                throw InferenceFailure(400, "unsupported-content-type")
            }
            part.optString("text")
        }
        else -> throw InferenceFailure(400, "unsupported-message-content")
    }

    private fun checkTextSize(value: String) {
        if (value.toByteArray(Charsets.UTF_8).size > AndeeInferencePolicy.MAX_TEXT_BYTES) {
            throw InferenceFailure(413, "message-too-large")
        }
    }

    private fun assistantChannels(message: JSONObject): Map<String, String> {
        val raw = message.optJSONObject("reasoning_details")
            ?: message.opt("reasoning") as? JSONObject
            ?: return emptyMap()
        return raw.keys().asSequence().associateWith { key -> raw.getString(key) }
    }

    private fun jsonMap(value: JSONObject): Map<String, Any?> =
        value.keys().asSequence().associateWith { key -> jsonValue(value.get(key)) }

    private fun jsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
        is String -> runCatching {
            val trimmed = value.trim()
            when {
                trimmed.startsWith("{") -> jsonMap(JSONObject(trimmed))
                trimmed.startsWith("[") -> jsonValue(JSONArray(trimmed))
                else -> value
            }
        }.getOrDefault(value)
        else -> value
    }

    private fun callId(model: String, call: ToolCall, index: Int): String {
        val source = "$model\u0000${call.name}\u0000${call.arguments}\u0000$index"
        return "call_${digestId(source)}"
    }

    private fun completionId(model: String, content: String): String {
        val source = "$model\u0000$content\u0000${System.nanoTime()}"
        return "chatcmpl_${digestId(source)}"
    }

    private fun digestId(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .copyOf(18)
        return Base64.encodeToString(
            digest,
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        )
    }

    private data class EngineKey(
        val modelSha256: String,
        val backend: String,
        val maxContextTokens: Int,
    )
    private data class ConversationInput(
        val initialMessages: List<Message>,
        val turn: Message,
    )
    private data class ToolBinding(val name: String, val provider: ToolProvider)

    private companion object {
        const val TAG = "AndeeInference"
        const val GOOGLE_TENSOR_SOUTHBOUND_LIBRARY = "edgetpu_litert"
        const val TIMEOUT_RESET_DELAY_MILLIS = 5_000L
        const val SHUTDOWN_RESET_DELAY_MILLIS = 15_000L
        const val OWNER_WAIT_MILLIS = 15_000L
        const val OWNER_RETRY_MILLIS = 100L
        val OWNER = AtomicBoolean(false)
    }
}
