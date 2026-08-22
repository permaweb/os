package org.permaweb.andee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndeeExecutionStorageTest {
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
