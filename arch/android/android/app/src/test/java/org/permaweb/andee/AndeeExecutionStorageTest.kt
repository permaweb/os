package org.permaweb.andee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.nio.file.Files
import java.io.File

class AndeeExecutionStorageTest {
    @Test
    fun executableReadinessUsesTheExecutionBoundaryChecks() {
        val root = Files.createTempDirectory("andock-runtime-").toFile()
        val ready = mapOf<String, Any>("state" to "ready", "stage" to "installing")
        try {
            val missing = andockExecutionHealth(ready, root)
            assertEquals("unavailable", missing["state"])
            assertEquals("execution-runtime-unavailable", missing["error"])
            assertEquals("missing packaged Andock launcher", assertThrows(IllegalArgumentException::class.java) {
                requireAndockRuntimeFiles(root)
            }.message)
            val paths = listOf("libandee_andock_launcher.so", "libandee_proot.so", "libandee_proot_loader.so")
                .map { File(root, it).apply { writeText("fixture"); setExecutable(true) } }
            assertEquals(ready, andockExecutionHealth(ready, root))
            assertEquals(paths, requireAndockRuntimeFiles(root).toList())
            paths.last().setExecutable(false)
            assertEquals("unavailable", andockExecutionHealth(ready, root)["state"])
            assertEquals("missing packaged PRoot loader", assertThrows(IllegalArgumentException::class.java) {
                requireAndockRuntimeFiles(root)
            }.message)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun executionAvailabilityNeverSkipsTemplatePreparation() {
        val absent = File("/andock-test-no-runtime")
        for (state in listOf("missing", "preparing", "failed")) {
            val template = mapOf<String, Any>("state" to state, "stage" to "installing")
            assertEquals(template, andockExecutionHealth(template, absent))
        }
    }

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
