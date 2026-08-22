package org.permaweb.andee

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

internal data class AndeeInferenceModel(
    val providerId: String,
    val id: String,
    val modelId: String,
    val materializedFile: File,
    val bytes: Long,
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

/** Resolves only providers, models, and BEAM-materialized paths in measured config. */
internal class AndeeInferenceModels(
    private val context: Context,
    configFile: File,
) {
    private val providers = parseProviders(readConfig(configFile))

    fun resolve(
        providerId: String?,
        requestedId: String?,
        materializedId: String,
        materializedPath: String,
        materializedBytes: Long,
    ): AndeeInferenceModel {
        val model = select(providerId, requestedId)
        validateRuntime(model)
        val issue = validateMaterialization(
            model,
            materializedId,
            materializedPath,
            materializedBytes,
        )
        issue?.let { reason ->
            throw InferenceFailure(
                503,
                reason,
                mapOf(
                    "provider" to model.providerId,
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
                    .put("andee-model-id", model.modelId),
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
            val materializationIssue = verifyMaterialized(model)
            val issue = runtimeIssue ?: materializationIssue
            val modelReady = issue == null && initialized(model)
            if (runtimeIssue == null) compatible += 1
            if (modelReady) ready += 1
            models.put(
                JSONObject()
                    .put("id", model.id)
                    .put("model-id", model.modelId)
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

    private fun select(providerId: String?, requestedId: String?): AndeeInferenceModel {
        val provider = provider(providerId)
        val id = requestedId
            ?.removePrefix("${provider.id}/")
            ?.takeIf(String::isNotBlank)
            ?: provider.defaultModel
        return provider.models.singleOrNull { it.id == id }
            ?: throw InferenceFailure(
                404,
                "unknown-model",
                mapOf("provider" to provider.id, "model" to id),
            )
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

    private fun validateMaterialization(
        model: AndeeInferenceModel,
        materializedId: String,
        materializedPath: String,
        materializedBytes: Long,
    ): String? {
        return validateMaterializedModel(
            model.modelId,
            model.materializedFile,
            model.bytes,
            materializedId,
            materializedPath,
            materializedBytes,
        )
    }

    private fun verifyMaterialized(model: AndeeInferenceModel): String? = when {
        !model.materializedFile.isFile -> "model-not-materialized"
        model.materializedFile.length() != model.bytes -> "model-byte-length-mismatch"
        !model.materializedFile.canRead() -> "model-is-not-readable"
        else -> null
    }

    private fun readConfig(configFile: File): JSONObject {
        require(configFile.isFile) {
            "missing effective config: ${configFile.absolutePath}"
        }
        return JSONObject(configFile.readText(Charsets.UTF_8))
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

    private companion object {
        val ARWEAVE_ID = Regex("^[A-Za-z0-9_-]{43}$")
        val GOOGLE_TENSOR_SOC = Regex("^Tensor G[3-6]$", RegexOption.IGNORE_CASE)
        val RUNTIMES = setOf("litert-lm", "llama-cpp")
        const val INFERENCE_DEVICE = "andee-inference@1.0"
        const val LLAMA_SERVER = "libandee_llama_server.so"
        const val MAX_MODELS = 64
        const val MAX_PROVIDERS = 64
    }
}

internal fun validateMaterializedModel(
    expectedId: String,
    expectedFile: File,
    expectedBytes: Long,
    materializedId: String,
    materializedPath: String,
    materializedBytes: Long,
): String? {
    if (materializedId != expectedId) return "model-id-mismatch"
    if (materializedBytes != expectedBytes) return "model-byte-length-mismatch"
    val expected = expectedFile.canonicalFile
    val actual = runCatching { File(materializedPath).canonicalFile }
        .getOrElse { return "invalid-model-path" }
    if (actual != expected) return "invalid-model-path"
    return when {
        !expectedFile.isFile -> "model-not-materialized"
        expectedFile.length() != expectedBytes -> "model-byte-length-mismatch"
        !expectedFile.canRead() -> "model-is-not-readable"
        else -> null
    }
}

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
