package org.permaweb.andee

internal class ExecutionFailure(
    val status: Int,
    message: String,
) : RuntimeException(message)
