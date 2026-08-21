package org.permaweb.andee

internal object AndeeInferencePolicy {
    const val PROTOCOL = "andee-inference-local@1"
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024
    const val MAX_MESSAGES = 256
    const val MAX_TOOLS = 128
    const val MAX_CONCURRENT_REQUESTS = 8
    const val SOCKET_TIMEOUT_MILLIS = 30_000
    const val GENERATION_TIMEOUT_MILLIS = 590_000L
    const val MAX_TEXT_BYTES = 4 * 1024 * 1024
    const val MAX_OUTPUT_TOKENS = 4096
    val BACKENDS = setOf("cpu", "gpu", "npu")
}

internal sealed interface AndeeToolChoice {
    data object Auto : AndeeToolChoice
    data object None : AndeeToolChoice
    data object Required : AndeeToolChoice
    data class Named(val name: String) : AndeeToolChoice
}

internal fun allowedToolNames(
    choice: AndeeToolChoice,
    supplied: Set<String>,
): Set<String> = when (choice) {
    AndeeToolChoice.Auto, AndeeToolChoice.Required -> supplied
    AndeeToolChoice.None -> emptySet()
    is AndeeToolChoice.Named -> {
        if (choice.name !in supplied) {
            throw InferenceFailure(400, "unknown-tool-choice")
        }
        setOf(choice.name)
    }
}

internal fun validateToolCalls(
    choice: AndeeToolChoice,
    allowed: Set<String>,
    returned: List<String>,
    truncated: Boolean,
) {
    if (returned.any { it !in allowed }) {
        throw InferenceFailure(502, "unknown-tool-call")
    }
    when (choice) {
        AndeeToolChoice.Auto -> Unit
        AndeeToolChoice.None -> Unit
        AndeeToolChoice.Required -> if (!truncated && returned.isEmpty()) {
            throw InferenceFailure(502, "tool-choice-not-satisfied")
        }
        is AndeeToolChoice.Named -> if (
            !truncated && returned.isEmpty()
        ) {
            throw InferenceFailure(502, "tool-choice-not-satisfied")
        }
    }
}

internal fun inferenceFinishReason(
    hasToolCalls: Boolean,
    decodedTokens: Int,
    maximumTokens: Int,
): String = when {
    hasToolCalls -> "tool_calls"
    decodedTokens >= maximumTokens -> "length"
    else -> "stop"
}

internal class InferenceFailure(
    val status: Int,
    message: String,
    val details: Map<String, Any?> = emptyMap(),
) : RuntimeException(message)
