package org.permaweb.andee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndeeExecutionStorageTest {
    @Test
    fun templateReadinessRequiresVerifiedInstallation() {
        val missing = "andock-default-image-not-materialized"
        assertEquals("missing", andockTemplateHealth(false, false, false, missing)["state"])
        assertEquals("preparing", andockTemplateHealth(false, true, false, missing)["state"])
        assertEquals("ready", andockTemplateHealth(true, false, false, "")["state"])
        assertEquals("unavailable", andockTemplateHealth(true, false, true, "")["state"])
    }

    @Test
    fun failedExpansionRemainsVisibleUntilAnExplicitRetry() {
        val failure = "insufficient-andock-template-storage"
        repeat(3) {
            val status = andockTemplateHealth(false, false, false, failure)
            assertEquals("failed", status["state"])
            assertEquals("installing", status["stage"])
            assertEquals(failure, status["error"])
        }
        assertEquals("preparing", andockTemplateHealth(false, true, false, failure)["state"])
    }

    @Test
    fun creationPreservesHostReserve() {
        val reserve = 512L * 1024 * 1024
        val template = 900L * 1024 * 1024

        assertTrue(hasAndockCreationCapacity(reserve + template, template))
        assertFalse(hasAndockCreationCapacity(reserve + template - 1, template))
        assertFalse(hasAndockCreationCapacity(reserve - 1, 1))
    }

    @Test
    fun expansionPreservesHostReserve() {
        val expanded = 32L * 1024 * 1024 * 1024

        assertEquals(
            expanded + 512L * 1024 * 1024,
            requiredExpansionSpace(expanded),
        )
    }
}
