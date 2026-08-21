package org.permaweb.andee

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import java.util.Locale

internal data class AndeeInferenceModel(
    val providerId: String,
    val id: String,
    val modelId: String,
    val materializedFile: File,
    val bytes: Long,
    val sha256: String,
    val runtime: String,
    val backend: String,
    val socModels: Set<String>,
    val maxContextTokens: Int,
    val maxOutputTokens: Int,
)

private data class AndeeInferenceProvider(
    val id: String,
    val defaultModel: String,
    val models: List<AndeeInferenceModel>,
)

/** Resolves only providers and models in the measured effective boot config. */
internal class AndeeInferenceModels(
    private val context: Context,
    configFile: File,
) {
    private val root = readConfig(configFile)
    private val materializer = AndeeModelMaterializer(
        AndeePaths.inferenceModelsRoot(context),
        gateway(root),
    )
    private val providers = parseProviders(root)
    private val verification = providers
        .flatMap(AndeeInferenceProvider::models)
        .associateWith { materializer.verify(it) }
        .toMutableMap()

    fun resolve(
        providerId: String?,
        requestedId: String?,
        deadlineMillis: Long,
    ): AndeeInferenceModel {
        val provider = provider(providerId)
        val id = requestedId
            ?.removePrefix("${provider.id}/")
            ?.takeIf(String::isNotBlank)
            ?: provider.defaultModel
        val model = provider.models.singleOrNull { it.id == id }
            ?: throw InferenceFailure(
                404,
                "unknown-model",
                mapOf("provider" to provider.id, "model" to id),
            )
        validateRuntime(model)
        val issue = materializer.ensure(model, deadlineMillis)
        verification[model] = issue
        issue?.let { reason ->
            throw InferenceFailure(
                if (reason == "generation-timed-out") 408 else 503,
                reason,
                mapOf(
                    "provider" to provider.id,
                    "model" to model.id,
                    "model-id" to model.modelId,
                ),
            )
        }
        return model
    }

    fun catalog(providerId: String?): JSONObject {
        val provider = provider(providerId)
        val data = JSONArray()
        provider.models.filter { runtimeIssue(it) == null }.forEach { model ->
            data.put(
                JSONObject()
                    .put("id", model.id)
                    .put("object", "model")
                    .put("owned_by", provider.id)
                    .put("name", model.id)
                    .put(
                        "architecture",
                        JSONObject().put("input_modalities", JSONArray().put("text")),
                    )
                    .put("andee-backend", model.backend)
                    .put("andee-runtime", model.runtime)
                    .put("andee-model-id", model.modelId)
                    .put("andee-model-sha256", model.sha256),
            )
        }
        return JSONObject().put("object", "list").put("data", data)
    }

    fun health(
        providerId: String?,
        initialized: (AndeeInferenceModel) -> Boolean,
    ): JSONObject {
        val provider = provider(providerId)
        val models = JSONArray()
        var compatible = 0
        var ready = 0
        provider.models.forEach { model ->
            val runtimeIssue = runtimeIssue(model)
            val materializationIssue = verification.getValue(model)
            val issue = runtimeIssue ?: materializationIssue
            val modelReady = issue == null && initialized(model)
            if (runtimeIssue == null) compatible += 1
            if (modelReady) ready += 1
            models.put(
                JSONObject()
                    .put("id", model.id)
                    .put("model-id", model.modelId)
                    .put("sha256", model.sha256)
                    .put("bytes", model.bytes)
                    .put("runtime", model.runtime)
                    .put("backend", model.backend)
                    .put("configured", runtimeIssue == null)
                    .put("materialized", materializationIssue == null)
                    .put("ready", modelReady)
                    .put("reason", issue ?: JSONObject.NULL),
            )
        }
        return JSONObject()
            .put(
                "status",
                when {
                    ready > 0 -> "healthy"
                    compatible > 0 -> "configured"
                    else -> "unavailable"
                },
            )
            .put("provider", provider.id)
            .put("default-model", provider.defaultModel)
            .put("npu-execution-verified", false)
            .put("soc-model", currentSocModel())
            .put("android-api", Build.VERSION.SDK_INT)
            .put("models", models)
    }

    private fun provider(requestedId: String?): AndeeInferenceProvider {
        val id = requestedId?.takeIf(String::isNotBlank)
        if (id == null && providers.size != 1) {
            throw InferenceFailure(400, "inference-provider-is-required")
        }
        return if (id == null) {
            providers.single()
        } else {
            providers.singleOrNull { it.id == id }
                ?: throw InferenceFailure(
                    404,
                    "unknown-inference-provider",
                    mapOf("provider" to id),
                )
        }
    }

    private fun readConfig(configFile: File): JSONObject {
        require(configFile.isFile) {
            "missing effective config: ${configFile.absolutePath}"
        }
        return JSONObject(configFile.readText(Charsets.UTF_8))
    }

    private fun gateway(root: JSONObject): String {
        val value = root.optString("gateway", DEFAULT_GATEWAY).trimEnd('/')
        val uri = URI(value)
        require(uri.scheme in setOf("http", "https") && uri.host != null) {
            "invalid Arweave gateway"
        }
        require(uri.userInfo == null && uri.query == null && uri.fragment == null) {
            "invalid Arweave gateway"
        }
        return value
    }

    private fun parseProviders(root: JSONObject): List<AndeeInferenceProvider> {
        val configured = root.optJSONObject("inference-providers") ?: JSONObject()
        val providerIds = configured.keys().asSequence().toList().sorted()
        require(providerIds.size <= MAX_PROVIDERS) {
            "too many configured inference providers"
        }
        return providerIds.mapNotNull { providerId ->
            val provider = configured.optJSONObject(providerId) ?: return@mapNotNull null
            if (provider.optString("inference-device") != INFERENCE_DEVICE) {
                return@mapNotNull null
            }
            require(providerId.length in 1..128 && providerId.all(::validIdCharacter)) {
                "invalid inference provider id"
            }
            parseProvider(providerId, provider)
        }.also { parsed ->
            require(parsed.isNotEmpty()) { "no AndEE inference provider is configured" }
            val networkIds = parsed.flatMap(AndeeInferenceProvider::models)
                .map(AndeeInferenceModel::modelId)
            require(networkIds.distinct().size == networkIds.size) {
                "duplicate inference model-id"
            }
        }
    }

    private fun parseProvider(
        providerId: String,
        provider: JSONObject,
    ): AndeeInferenceProvider {
        val models = provider.optJSONArray("models") ?: JSONArray()
        require(models.length() in 1..MAX_MODELS) {
            "invalid configured inference model count"
        }
        val parsed = (0 until models.length()).map { index ->
            parseModel(providerId, models.getJSONObject(index))
        }
        require(parsed.map(AndeeInferenceModel::id).distinct().size == parsed.size) {
            "duplicate inference model id"
        }
        val defaultModel = provider.getString("default-model")
        require(parsed.any { it.id == defaultModel }) {
            "unknown default inference model"
        }
        return AndeeInferenceProvider(providerId, defaultModel, parsed)
    }

    private fun parseModel(
        providerId: String,
        item: JSONObject,
    ): AndeeInferenceModel {
        val id = item.getString("id")
        require(id.length in 1..128 && id.all(::validIdCharacter)) {
            "invalid inference model id"
        }
        val modelId = item.getString("model-id")
        require(ARWEAVE_ID.matches(modelId)) { "invalid inference model-id" }
        val runtime = item.getString("runtime")
        require(runtime in RUNTIMES) { "unsupported inference model runtime" }
        val backend = item.getString("backend").lowercase(Locale.US)
        validateBackend(backend)
        require(runtime != "llama-cpp" || backend == "cpu") {
            "llama.cpp inference models are CPU-only"
        }
        val socModels = item.optJSONArray("soc-models")?.let(::stringSet).orEmpty()
        require(backend != "npu" || socModels.isNotEmpty()) {
            "NPU inference models require an explicit SoC allowlist"
        }
        require(backend != "npu" || socModels.all { GOOGLE_TENSOR_SOC.matches(it) }) {
            "pinned NPU runtime supports Google Tensor G3 through G6 only"
        }
        val bytes = item.getLong("bytes")
        require(bytes > 0) { "invalid inference model byte length" }
        val sha256 = item.getString("sha256")
        require(decodeDigest(sha256).size == 32) { "invalid inference model digest" }
        val maxContextTokens = item.optInt("max-context-tokens", 1280)
        require(maxContextTokens in 128..32768) { "invalid inference model context limit" }
        val maxOutputTokens = item.optInt("max-output-tokens", 256)
        require(maxOutputTokens in 1..AndeeInferencePolicy.MAX_OUTPUT_TOKENS) {
            "invalid inference model output limit"
        }
        val extension = if (runtime == "litert-lm") ".litertlm" else ".gguf"
        return AndeeInferenceModel(
            providerId = providerId,
            id = id,
            modelId = modelId,
            materializedFile = File(
                AndeePaths.inferenceModelsRoot(context),
                modelId + extension,
            ),
            bytes = bytes,
            sha256 = sha256,
            runtime = runtime,
            backend = backend,
            socModels = socModels,
            maxContextTokens = maxContextTokens,
            maxOutputTokens = maxOutputTokens,
        )
    }

    private fun validateRuntime(model: AndeeInferenceModel) {
        runtimeIssue(model)?.let { issue -> throw InferenceFailure(503, issue) }
    }

    private fun runtimeIssue(model: AndeeInferenceModel): String? {
        if (model.runtime == "llama-cpp") {
            if (Build.SUPPORTED_ABIS.none { it == "arm64-v8a" }) {
                return "llama-cpp-requires-arm64"
            }
            llamaCppMemoryIssue(model.bytes, androidPhysicalMemoryBytes())
                ?.let { return it }
            val server = File(context.applicationInfo.nativeLibraryDir, LLAMA_SERVER)
            return if (server.isFile && server.canExecute()) {
                null
            } else {
                "llama-cpp-runtime-missing"
            }
        }
        if (model.socModels.isNotEmpty()) {
            val current = currentSocModel().lowercase(Locale.US)
            if (model.socModels.none { it.lowercase(Locale.US) == current }) {
                return "model-soc-mismatch"
            }
        }
        if (model.backend != "npu") return null
        if (Build.VERSION.SDK_INT < 31) return "npu-requires-android-31"
        if (Build.SUPPORTED_ABIS.none { it == "arm64-v8a" }) {
            return "npu-requires-arm64"
        }
        val dispatch = File(
            context.applicationInfo.nativeLibraryDir,
            "libLiteRtDispatch_GoogleTensor.so",
        )
        return if (dispatch.isFile) null else "npu-dispatch-runtime-missing"
    }

    private fun validateBackend(backend: String) {
        if (backend !in AndeeInferencePolicy.BACKENDS) {
            throw InferenceFailure(
                400,
                "unsupported-backend",
                mapOf("backend" to backend),
            )
        }
    }

    private fun stringSet(values: JSONArray): Set<String> =
        (0 until values.length()).map { values.getString(it) }.toSet()

    private fun validIdCharacter(value: Char): Boolean =
        value.isLetterOrDigit() || value in "._-"

    private fun decodeDigest(value: String): ByteArray = Base64.decode(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private companion object {
        val ARWEAVE_ID = Regex("^[A-Za-z0-9_-]{43}$")
        val GOOGLE_TENSOR_SOC = Regex("^Tensor G[3-6]$", RegexOption.IGNORE_CASE)
        val RUNTIMES = setOf("litert-lm", "llama-cpp")
        const val DEFAULT_GATEWAY = "https://arweave.net"
        const val INFERENCE_DEVICE = "andee-inference@1.0"
        const val LLAMA_SERVER = "libandee_llama_server.so"
        const val MAX_MODELS = 64
        const val MAX_PROVIDERS = 64
    }
}

private class AndeeModelMaterializer(
    private val root: File,
    private val gateway: String,
) {
    @Synchronized
    fun ensure(model: AndeeInferenceModel, deadlineMillis: Long): String? {
        verify(model, deadlineMillis)?.let { issue ->
            if (issue in setOf("model-byte-length-mismatch", "model-digest-mismatch")) {
                model.materializedFile.delete()
            } else if (issue != "model-not-materialized") {
                return issue
            }
        } ?: return null
        if (SystemClock.elapsedRealtime() >= deadlineMillis) {
            return "generation-timed-out"
        }
        root.mkdirs()
        if (root.usableSpace < model.bytes + DOWNLOAD_HEADROOM_BYTES) {
            return "insufficient-model-storage"
        }
        val partial = File(root, "${model.materializedFile.name}.part")
        partial.delete()
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        return try {
            source(model, deadlineMillis).let { source ->
                partial.outputStream().buffered().use { output ->
                    source.forEach { chunk ->
                        count += streamTransaction(
                            chunk.id,
                            chunk.bytes,
                            output,
                            digest,
                            deadlineMillis,
                        )
                    }
                }
            }
            if (count != model.bytes) throw MaterializationFailure(
                "model-byte-length-mismatch",
            )
            if (base64Url(digest.digest()) != model.sha256) {
                throw MaterializationFailure("model-digest-mismatch")
            }
            if (!partial.renameTo(model.materializedFile)) {
                throw MaterializationFailure("model-materialization-failed")
            }
            model.materializedFile.setReadOnly()
            null
        } catch (failure: MaterializationFailure) {
            failure.reason
        } catch (_: Exception) {
            "model-fetch-failed"
        } finally {
            if (partial.exists()) partial.delete()
        }
    }

    private fun source(
        model: AndeeInferenceModel,
        deadlineMillis: Long,
    ): List<ModelChunk> {
        val connection = connection(model.modelId, deadlineMillis)
        return try {
            val contentType = connection.contentType
                ?.substringBefore(';')
                ?.trim()
                ?.lowercase(Locale.US)
            if (contentType == MANIFEST_CONTENT_TYPE) {
                parseManifest(readManifest(connection, deadlineMillis), model)
            } else {
                listOf(ModelChunk(model.modelId, model.bytes))
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun readManifest(
        connection: HttpURLConnection,
        deadlineMillis: Long,
    ): JSONObject {
        var count = 0
        val bytes = connection.inputStream.use { input ->
            buildList<ByteArray> {
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    checkDeadline(deadlineMillis)
                    val read = input.read(buffer)
                    if (read < 0) break
                    count += read
                    if (count > MAX_MANIFEST_BYTES) {
                        throw MaterializationFailure("invalid-model-manifest")
                    }
                    add(buffer.copyOf(read))
                }
                buffer.fill(0)
            }.let { chunks ->
                ByteArray(count).also { result ->
                    var offset = 0
                    chunks.forEach { chunk ->
                        chunk.copyInto(result, offset)
                        offset += chunk.size
                        chunk.fill(0)
                    }
                }
            }
        }
        return try {
            JSONObject(String(bytes, Charsets.UTF_8))
        } finally {
            bytes.fill(0)
        }
    }

    private fun parseManifest(
        manifest: JSONObject,
        model: AndeeInferenceModel,
    ): List<ModelChunk> {
        if (
            manifest.optString("format") != MANIFEST_FORMAT ||
            manifest.optLong("model-bytes", -1L) != model.bytes ||
            manifest.optString("model-sha256") != model.sha256
        ) {
            throw MaterializationFailure("invalid-model-manifest")
        }
        val entries = manifest.optJSONArray("chunks")
            ?: throw MaterializationFailure("invalid-model-manifest")
        if (entries.length() !in 1..MAX_MANIFEST_CHUNKS) {
            throw MaterializationFailure("invalid-model-manifest")
        }
        val chunks = (0 until entries.length()).map { index ->
            val entry = entries.optJSONObject(index)
                ?: throw MaterializationFailure("invalid-model-manifest")
            val id = entry.optString("id")
            val bytes = entry.optLong("bytes", -1L)
            if (!ARWEAVE_ID.matches(id) || bytes <= 0L || bytes > MAX_CHUNK_BYTES) {
                throw MaterializationFailure("invalid-model-manifest")
            }
            ModelChunk(id, bytes)
        }
        if (
            chunks.map(ModelChunk::id).distinct().size != chunks.size ||
            chunks.sumOf(ModelChunk::bytes) != model.bytes
        ) {
            throw MaterializationFailure("invalid-model-manifest")
        }
        return chunks
    }

    private fun streamTransaction(
        id: String,
        expectedBytes: Long,
        output: OutputStream,
        digest: MessageDigest,
        deadlineMillis: Long,
    ): Long {
        val connection = connection(id, deadlineMillis)
        return try {
            var count = 0L
            connection.inputStream.use { input ->
                val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                while (true) {
                    checkDeadline(deadlineMillis)
                    val read = input.read(buffer)
                    if (read < 0) break
                    count += read
                    if (count > expectedBytes) {
                        throw MaterializationFailure("model-byte-length-mismatch")
                    }
                    digest.update(buffer, 0, read)
                    output.write(buffer, 0, read)
                }
                buffer.fill(0)
            }
            if (count != expectedBytes) {
                throw MaterializationFailure("model-byte-length-mismatch")
            }
            count
        } finally {
            connection.disconnect()
        }
    }

    private fun connection(
        id: String,
        deadlineMillis: Long,
    ): HttpURLConnection {
        checkDeadline(deadlineMillis)
        val connection = URL("$gateway/$id").openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = minOf(
            CONNECT_TIMEOUT_MS,
            remainingReadTimeout(deadlineMillis),
        )
        connection.readTimeout = remainingReadTimeout(deadlineMillis)
        connection.setRequestProperty(
            "Accept",
            "$MANIFEST_CONTENT_TYPE, application/octet-stream",
        )
        if (connection.responseCode !in 200..299) {
            connection.disconnect()
            throw MaterializationFailure("model-fetch-failed")
        }
        return connection
    }

    private fun checkDeadline(deadlineMillis: Long) {
        if (SystemClock.elapsedRealtime() >= deadlineMillis) {
            throw MaterializationFailure("generation-timed-out")
        }
    }

    fun verify(
        model: AndeeInferenceModel,
        deadlineMillis: Long = Long.MAX_VALUE,
    ): String? {
        if (!model.materializedFile.isFile) return "model-not-materialized"
        if (model.materializedFile.length() != model.bytes) {
            return "model-byte-length-mismatch"
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        model.materializedFile.inputStream().use { input ->
            while (true) {
                if (SystemClock.elapsedRealtime() >= deadlineMillis) {
                    return "generation-timed-out"
                }
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        buffer.fill(0)
        return if (base64Url(digest.digest()) == model.sha256) {
            null
        } else {
            "model-digest-mismatch"
        }
    }

    private fun base64Url(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private fun remainingReadTimeout(deadlineMillis: Long): Int {
        val remaining = deadlineMillis - SystemClock.elapsedRealtime()
        if (remaining <= 0L) return 1
        return minOf(READ_TIMEOUT_MS.toLong(), remaining).toInt().coerceAtLeast(1)
    }

    private companion object {
        val ARWEAVE_ID = Regex("^[A-Za-z0-9_-]{43}$")
        const val MANIFEST_FORMAT = "permawebos/andee-model/1"
        const val MANIFEST_CONTENT_TYPE = "application/vnd.permawebos.andee-model+json"
        const val CONNECT_TIMEOUT_MS = 30_000
        const val READ_TIMEOUT_MS = 30_000
        const val DOWNLOAD_BUFFER_BYTES = 1024 * 1024
        const val DOWNLOAD_HEADROOM_BYTES = 256L * 1024L * 1024L
        const val MAX_MANIFEST_BYTES = 1024 * 1024
        const val MAX_MANIFEST_CHUNKS = 128
        const val MAX_CHUNK_BYTES = 100_000_000L
    }
}

private data class ModelChunk(val id: String, val bytes: Long)

private class MaterializationFailure(val reason: String) : Exception(reason)

internal fun llamaCppMemoryIssue(modelBytes: Long, memoryBytes: Long): String? = when {
    memoryBytes <= 0L -> "llama-cpp-memory-unavailable"
    modelBytes > memoryBytes - LLAMA_CPP_MEMORY_HEADROOM_BYTES ->
        "llama-cpp-insufficient-memory"
    else -> null
}

internal const val LLAMA_CPP_MEMORY_HEADROOM_BYTES = 4L * 1024L * 1024L * 1024L

internal fun androidPhysicalMemoryBytes(): Long = runCatching {
    File("/proc/meminfo").useLines { lines ->
        lines.first { it.startsWith("MemTotal:") }
            .split(Regex("\\s+"))[1]
            .toLong() * 1024L
    }
}.getOrDefault(0L)

internal fun currentSocModel(): String = if (Build.VERSION.SDK_INT >= 31) {
    Build.SOC_MODEL.takeIf(String::isNotBlank) ?: "unknown"
} else {
    Build.HARDWARE.takeIf(String::isNotBlank) ?: "unknown"
}
