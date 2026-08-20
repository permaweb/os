package org.permaweb.andee

import android.content.Context
import android.os.Build
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.Locale

internal data class AndeeInferenceModel(
    val id: String,
    val file: File,
    val sha256: String,
    val runtime: String,
    val backends: Set<String>,
    val socModels: Set<String>,
    val maxContextTokens: Int,
    val maxOutputTokens: Int,
)

/** Resolves only models allowlisted by the measured effective boot config. */
internal class AndeeInferenceModels(
    private val context: Context,
    configFile: File,
) {
    private val inferenceConfig = readConfig(configFile)
    val backend = inferenceConfig?.optString("backend", "npu")
        ?.lowercase(Locale.US)
        ?.also(::validateBackend)
        ?: "npu"
    private val configured = parseConfig(inferenceConfig)
    private val verification = configured.associateWith(::verify)

    fun resolve(requestedId: String?, backend: String): AndeeInferenceModel {
        validateBackend(backend)
        val id = requestedId
            ?.removePrefix("local/")
            ?.takeIf(String::isNotBlank)
        val candidates = configured.filter { model ->
            (id == null || model.id == id) && backend in model.backends
        }
        if (candidates.isEmpty()) {
            throw InferenceFailure(
                404,
                if (id == null) "no-model-for-backend" else "unknown-model",
                mapOf("backend" to backend, "model" to id),
            )
        }
        if (id == null && candidates.size != 1) {
            throw InferenceFailure(400, "model-is-required")
        }
        val model = candidates.single()
        verification.getValue(model)?.let { reason ->
            throw InferenceFailure(
                503,
                reason,
                mapOf("backend" to backend, "model" to model.id),
            )
        }
        validateRuntime(model, backend)
        return model
    }

    fun catalog(backend: String): JSONObject {
        validateBackend(backend)
        val data = JSONArray()
        configured
            .filter { backend in it.backends && verification.getValue(it) == null }
            .filter { runtimeIssue(it, backend) == null }
            .forEach { model ->
                data.put(
                    JSONObject()
                        .put("id", model.id)
                        .put("object", "model")
                        .put("owned_by", "andee")
                        .put("name", model.id)
                        .put(
                            "architecture",
                            JSONObject().put("input_modalities", JSONArray().put("text")),
                        )
                        .put("andee-backend", backend)
                        .put("andee-runtime", model.runtime)
                        .put("andee-model-sha256", model.sha256),
                )
            }
        return JSONObject().put("object", "list").put("data", data)
    }

    fun health(
        backend: String,
        initialized: (AndeeInferenceModel) -> Boolean,
    ): JSONObject {
        validateBackend(backend)
        val models = JSONArray()
        var compatible = 0
        var ready = 0
        configured.forEach { model ->
            val issue = verification.getValue(model) ?: runtimeIssue(model, backend)
            val modelReady = issue == null && initialized(model)
            if (issue == null) compatible += 1
            if (modelReady) ready += 1
            models.put(
                JSONObject()
                    .put("id", model.id)
                    .put("sha256", model.sha256)
                    .put("runtime", model.runtime)
                    .put("backends", JSONArray(model.backends.sorted()))
                    .put("configured", issue == null)
                    .put("ready", modelReady)
                    .put("reason", issue ?: JSONObject.NULL),
            )
        }
        return JSONObject()
            .put(
                "status",
                when {
                    configured.isEmpty() -> "unconfigured"
                    ready > 0 -> "healthy"
                    compatible > 0 -> "configured"
                    else -> "unavailable"
                },
            )
            .put("provider", "local")
            .put("backend", backend)
            .put("npu-execution-verified", false)
            .put("soc-model", currentSocModel())
            .put("android-api", Build.VERSION.SDK_INT)
            .put("models", models)
    }

    private fun readConfig(configFile: File): JSONObject? {
        require(configFile.isFile) { "missing effective config: ${configFile.absolutePath}" }
        val root = JSONObject(configFile.readText(Charsets.UTF_8))
        return root.optJSONObject("andee-inference")
    }

    private fun parseConfig(inference: JSONObject?): List<AndeeInferenceModel> {
        if (inference == null) return emptyList()
        val models = inference.optJSONArray("models") ?: return emptyList()
        require(models.length() <= 64) { "too many configured inference models" }
        return (0 until models.length()).map { index ->
            val item = models.getJSONObject(index)
            val id = item.getString("id")
            require(id.length in 1..128 && id.all(::validIdCharacter)) {
                "invalid inference model id"
            }
            val filename = item.getString("file")
            val runtime = item.getString("runtime")
            require(runtime in RUNTIMES) { "unsupported inference model runtime" }
            val extension = if (runtime == "litert-lm") ".litertlm" else ".gguf"
            require(filename.length in 1..255 && filename.endsWith(extension)) {
                "inference model file does not match its runtime"
            }
            require(filename == File(filename).name) { "inference model path is not allowed" }
            val backends = stringSet(item.getJSONArray("backends"))
            require(backends.isNotEmpty() && backends.all { it in AndeeInferencePolicy.BACKENDS }) {
                "invalid inference model backends"
            }
            require(runtime != "llama-cpp" || backends == setOf("cpu")) {
                "llama.cpp inference models are CPU-only"
            }
            val socModels = item.optJSONArray("soc-models")?.let(::stringSet).orEmpty()
            require("npu" !in backends || socModels.isNotEmpty()) {
                "NPU inference models require an explicit SoC allowlist"
            }
            require(
                "npu" !in backends || socModels.all { GOOGLE_TENSOR_SOC.matches(it) },
            ) {
                "pinned NPU runtime supports Google Tensor G3 through G6 only"
            }
            val sha256 = item.getString("sha256")
            require(decodeDigest(sha256).size == 32) { "invalid inference model digest" }
            val maxContextTokens = item.optInt("max-context-tokens", 1280)
            require(maxContextTokens in 128..32768) { "invalid inference model context limit" }
            val maxOutputTokens = item.optInt("max-output-tokens", 256)
            require(maxOutputTokens in 1..AndeeInferencePolicy.MAX_OUTPUT_TOKENS) {
                "invalid inference model output limit"
            }
            AndeeInferenceModel(
                id = id,
                file = File(AndeePaths.inferenceModelsRoot(context), filename),
                sha256 = sha256,
                runtime = runtime,
                backends = backends,
                socModels = socModels,
                maxContextTokens = maxContextTokens,
                maxOutputTokens = maxOutputTokens,
            )
        }.also { parsed ->
            require(parsed.map(AndeeInferenceModel::id).distinct().size == parsed.size) {
                "duplicate inference model id"
            }
            require(parsed.map { it.file.name }.distinct().size == parsed.size) {
                "duplicate inference model file"
            }
        }
    }

    private fun verify(model: AndeeInferenceModel): String? {
        if (!model.file.isFile) return "model-file-missing"
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        model.file.inputStream().use { input ->
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        buffer.fill(0)
        return if (base64Url(digest.digest()) == model.sha256) null else "model-digest-mismatch"
    }

    private fun validateRuntime(model: AndeeInferenceModel, backend: String) {
        runtimeIssue(model, backend)?.let { issue -> throw InferenceFailure(503, issue) }
    }

    private fun runtimeIssue(model: AndeeInferenceModel, backend: String): String? {
        if (backend !in model.backends) return "model-backend-mismatch"
        if (model.runtime == "llama-cpp") {
            if (Build.SUPPORTED_ABIS.none { it == "arm64-v8a" }) {
                return "llama-cpp-requires-arm64"
            }
            llamaCppMemoryIssue(model.file.length(), androidPhysicalMemoryBytes())
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
        if (backend != "npu") return null
        if (Build.VERSION.SDK_INT < 31) return "npu-requires-android-31"
        if (Build.SUPPORTED_ABIS.none { it == "arm64-v8a" }) return "npu-requires-arm64"
        val dispatch = File(
            context.applicationInfo.nativeLibraryDir,
            "libLiteRtDispatch_GoogleTensor.so",
        )
        if (!dispatch.isFile) return "npu-dispatch-runtime-missing"
        return null
    }

    private fun validateBackend(backend: String) {
        if (backend !in AndeeInferencePolicy.BACKENDS) {
            throw InferenceFailure(400, "unsupported-backend", mapOf("backend" to backend))
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

    private fun base64Url(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private companion object {
        val GOOGLE_TENSOR_SOC = Regex("^Tensor G[3-6]$", RegexOption.IGNORE_CASE)
        val RUNTIMES = setOf("litert-lm", "llama-cpp")
        const val LLAMA_SERVER = "libandee_llama_server.so"
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
