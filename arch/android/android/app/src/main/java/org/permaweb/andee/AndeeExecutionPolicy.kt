package org.permaweb.andee

/** Security and resource limits for the packaged Andock runtime. */
internal object AndeeExecutionPolicy {
    const val MAX_ACTIVE_MEMBERS = 8
    const val MAX_REQUEST_BYTES = 72 * 1024 * 1024
    const val MAX_TIMEOUT_MS = 30 * 60 * 1000
    const val MAX_OUTPUT_BYTES = 50 * 1024 * 1024
    const val MAX_ERROR_BYTES = 64 * 1024
}
