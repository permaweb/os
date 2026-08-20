package org.permaweb.andee

import android.content.Context
import android.util.Log
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Owns the measured model catalogue, local engines, and private transport. */
internal class AndeeInferenceManager(
    private val context: Context,
    configFile: File,
) : AutoCloseable {
    private val models = AndeeInferenceModels(context, configFile)
    private val liteRtEngine = AndeeInferenceEngine(context)
    private val llamaCppEngine = AndeeLlamaCppEngine(context)
    private val server = AndeeInferenceServer(context, ::dispatch, ::failureResponse)
    private val completionLock = ReentrantLock(true)
    @Volatile private var running = false

    fun start() {
        check(!running) { "inference manager is already running" }
        AndeePaths.inferenceCacheRoot(context).mkdirs()
        running = true
        try {
            server.start()
        } catch (failure: Throwable) {
            running = false
            llamaCppEngine.close()
            liteRtEngine.close()
            throw failure
        }
    }

    override fun close() {
        running = false
        server.close()
        llamaCppEngine.close()
        liteRtEngine.close()
    }

    private fun dispatch(request: JSONObject): JSONObject {
        check(running) { "inference manager is stopped" }
        if (request.optString("protocol") != AndeeInferencePolicy.PROTOCOL) {
            throw InferenceFailure(400, "unsupported-protocol")
        }
        if (request.has("backend")) {
            throw InferenceFailure(400, "backend-is-measured-configuration")
        }
        val backend = models.backend
        return when (request.getString("action")) {
            "models" -> success(models.catalog(backend))
            "health" -> success(
                models.health(backend) { model ->
                    when (model.runtime) {
                        "litert-lm" -> liteRtEngine.isInitialized(model, backend)
                        "llama-cpp" -> llamaCppEngine.isInitialized(model, backend)
                        else -> false
                    }
                },
            )
            "completions" -> {
                val payload = request.getJSONObject("payload")
                val selected = models.resolve(request.optString("model"), backend)
                success(
                    completionLock.withLock {
                        when (selected.runtime) {
                            "litert-lm" -> {
                                llamaCppEngine.releaseModel()
                                liteRtEngine.complete(selected, backend, payload)
                            }
                            "llama-cpp" -> {
                                liteRtEngine.releaseModel()
                                llamaCppEngine.complete(selected, backend, payload)
                            }
                            else -> throw InferenceFailure(500, "invalid-model-runtime")
                        }
                    },
                )
            }
            else -> throw InferenceFailure(404, "unknown-action")
        }
    }

    private fun success(body: JSONObject): JSONObject =
        JSONObject().put("ok", true).put("body", body)

    private fun failureResponse(failure: Throwable): JSONObject {
        val inferenceFailure = when (failure) {
            is InferenceFailure -> failure
            is JSONException -> InferenceFailure(400, "invalid-request-json")
            else -> null
        }
        if (inferenceFailure == null) {
            Log.e(TAG, "inference request failed", failure)
        }
        val response = JSONObject()
            .put("ok", false)
            .put("status", inferenceFailure?.status ?: 500)
            .put("error", inferenceFailure?.message ?: "inference-failed")
        inferenceFailure?.details?.forEach { (key, value) -> response.put(key, value) }
        return response
    }

    private companion object {
        const val TAG = "AndeeInference"
    }
}
