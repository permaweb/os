package org.permaweb.andee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class AndeeInferencePolicyTest {
    @Test
    fun namedChoiceExposesAndAcceptsOnlyTheSelectedTool() {
        val choice = AndeeToolChoice.Named("Send")
        val allowed = allowedToolNames(choice, setOf("List", "Send"))

        assertEquals(setOf("Send"), allowed)
        validateToolCalls(choice, allowed, listOf("Send"), truncated = false)
        assertThrows(InferenceFailure::class.java) {
            validateToolCalls(choice, allowed, listOf("List"), truncated = false)
        }
        assertThrows(InferenceFailure::class.java) {
            validateToolCalls(choice, allowed, emptyList(), truncated = false)
        }
        validateToolCalls(choice, allowed, emptyList(), truncated = true)
    }

    @Test
    fun noneAndRequiredChoicesAreEnforced() {
        assertEquals(
            emptySet<String>(),
            allowedToolNames(AndeeToolChoice.None, setOf("Send")),
        )
        validateToolCalls(AndeeToolChoice.None, emptySet(), emptyList(), truncated = false)
        validateToolCalls(
            AndeeToolChoice.Required,
            setOf("Send"),
            listOf("Send"),
            truncated = false,
        )
        assertThrows(InferenceFailure::class.java) {
            validateToolCalls(
                AndeeToolChoice.None,
                emptySet(),
                listOf("Send"),
                truncated = false,
            )
        }
        assertThrows(InferenceFailure::class.java) {
            validateToolCalls(
                AndeeToolChoice.Required,
                setOf("Send"),
                emptyList(),
                truncated = false,
            )
        }
        validateToolCalls(
            AndeeToolChoice.Required,
            setOf("Send"),
            emptyList(),
            truncated = true,
        )
    }

    @Test
    fun autoAndRequiredRejectToolsThatWereNotSupplied() {
        listOf(AndeeToolChoice.Auto, AndeeToolChoice.Required).forEach { choice ->
            assertThrows(InferenceFailure::class.java) {
                validateToolCalls(
                    choice,
                    setOf("Send"),
                    listOf("Hallucinated"),
                    truncated = false,
                )
            }
        }
    }

    @Test
    fun unknownNamedChoiceIsRejectedBeforeGeneration() {
        assertThrows(InferenceFailure::class.java) {
            allowedToolNames(AndeeToolChoice.Named("Missing"), setOf("Send"))
        }
    }

    @Test
    fun tokenLimitIsReportedAsResumable() {
        assertEquals("tool_calls", inferenceFinishReason(true, 64, 64))
        assertEquals("length", inferenceFinishReason(false, 64, 64))
        assertEquals("stop", inferenceFinishReason(false, 19, 64))
    }

    @Test
    fun liteRtContextOverflowIsAnExplicitClientError() {
        val failure = checkNotNull(
            liteRtInferenceFailure(
                "Failed to call nativeSendMessage: INVALID_ARGUMENT: Input token ids are too " +
                    "long. Exceeding the maximum number of tokens allowed: 3192 >= 1280",
            ),
        )

        assertEquals(400, failure.status)
        assertEquals("context-window-exceeded", failure.message)
        assertEquals(3192, failure.details["input-tokens"])
        assertEquals(1280, failure.details["max-context-tokens"])
        assertNull(liteRtInferenceFailure("INVALID_ARGUMENT: another failure"))
    }

    @Test
    fun llamaCppLeavesFourGiBOfPhysicalHeadroom() {
        val sixteenGiB = 16L * 1024L * 1024L * 1024L
        assertNull(llamaCppMemoryIssue(12L * 1024L * 1024L * 1024L, sixteenGiB))
        assertEquals(
            "llama-cpp-insufficient-memory",
            llamaCppMemoryIssue(12L * 1024L * 1024L * 1024L + 1L, sixteenGiB),
        )
        assertEquals(
            "llama-cpp-memory-unavailable",
            llamaCppMemoryIssue(1L, 0L),
        )
    }
}
