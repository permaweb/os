package org.permaweb.andee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.file.Files

class AndeeMaterializedModelTest {
    @Test
    fun acceptsOnlyTheIdDerivedFileWithTheMeasuredLength() {
        val root = Files.createTempDirectory("andee-model-boundary").toFile()
        try {
            val id = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            val model = root.resolve("$id.litertlm")
            model.writeBytes(byteArrayOf(1, 2, 3, 4))

            assertNull(validateMaterializedModel(id, model, 4, id, model.path, 4))
            assertEquals(
                "model-id-mismatch",
                validateMaterializedModel(id, model, 4, "B".repeat(43), model.path, 4),
            )
            assertEquals(
                "invalid-model-path",
                validateMaterializedModel(id, model, 4, id, root.resolve("other").path, 4),
            )
            assertEquals(
                "model-byte-length-mismatch",
                validateMaterializedModel(id, model, 4, id, model.path, 3),
            )
        } finally {
            root.deleteRecursively()
        }
    }
}
