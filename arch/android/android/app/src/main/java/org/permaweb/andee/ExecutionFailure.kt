package org.permaweb.andee

internal class ExecutionFailure(
    val status: Int,
    message: String,
    val details: Map<String, Any?> = emptyMap(),
    val nonfatalWorkerContention: Boolean = false,
) : RuntimeException(message)
