package org.permaweb.andee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndeeExecutionContentionTest {
    @Test
    fun contentionPreservesTheActiveWorker() {
        assertFalse(
            shouldStopWorkerAfterFailure(
                ExecutionFailure(
                    409,
                    "member-busy",
                    nonfatalWorkerContention = true,
                ),
            ),
        )
        assertFalse(
            shouldStopWorkerAfterFailure(
                ExecutionFailure(
                    429,
                    "isolated-execution-capacity-reached",
                    nonfatalWorkerContention = true,
                ),
            ),
        )
    }

    @Test
    fun fatalFailuresStillRequireWorkerCleanup() {
        assertTrue(shouldStopWorkerAfterFailure(ExecutionFailure(500, "worker-failed")))
        assertTrue(shouldStopWorkerAfterFailure(IllegalStateException("binder-failed")))
    }

    @Test
    fun activeSessionResponseHasMachineUsableControlGuidance() {
        val details = memberSessionActiveDetails("session-123", "running")

        assertEquals("session-123", details["session-id"])
        assertEquals("running", details["execution-status"])
        assertEquals("bash-session", details["session-control-action"])
        assertEquals(
            listOf("poll", "wait", "terminate"),
            details["session-control-operations"],
        )
        assertEquals("session-terminal", details["retry-when"])
    }

    @Test
    fun memberCancellationRepeatsInsideTheLock() {
        val events = mutableListOf<String>()

        val result = withMemberCancellationFence(
            cancel = { events += "cancel" },
            withLock = { action ->
                events += "lock"
                action()
            },
        ) {
            events += "action"
            "stopped"
        }

        assertEquals("stopped", result)
        assertEquals(listOf("cancel", "lock", "cancel", "action"), events)
    }
}
