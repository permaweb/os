package org.permaweb.andee

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

class AndroidSparseImageTest {
    @Test
    fun expandsRawFillAndHoleChunksAndVerifiesTheFullDigest() {
        val sparse = sparseImage()
        val output = temporaryFile()
        try {
            val result = AndroidSparseImage.expand(ByteArrayInputStream(sparse), output)
            val expected = ByteArray(4 * BLOCK_BYTES)
            expected.fill(0x7a, 0, BLOCK_BYTES)
            for (index in BLOCK_BYTES until 2 * BLOCK_BYTES) {
                expected[index] = byteArrayOf(1, 2, 3, 4)[index % 4]
            }

            assertEquals(expected.size.toLong(), result.bytes)
            assertEquals(sha256(expected), result.sha256)
            assertArrayEquals(expected, output.readBytes())
        } finally {
            output.delete()
        }
    }

    @Test
    fun rejectsTrailingBytesAndDeletesThePartialOutput() {
        val output = temporaryFile()
        val sparse = sparseImage() + byteArrayOf(1)
        try {
            assertThrows(IllegalArgumentException::class.java) {
                AndroidSparseImage.expand(ByteArrayInputStream(sparse), output)
            }
            assertEquals(false, output.exists())
        } finally {
            output.delete()
        }
    }

    @Test
    fun rejectsTruncatedImagesAndDeletesThePartialOutput() {
        val output = temporaryFile()
        val sparse = sparseImage().copyOf(sparseImage().size - 1)
        try {
            assertThrows(Exception::class.java) {
                AndroidSparseImage.expand(ByteArrayInputStream(sparse), output)
            }
            assertEquals(false, output.exists())
        } finally {
            output.delete()
        }
    }

    private fun sparseImage(): ByteArray = ByteArrayOutputStream().also { output ->
        output.littleInt(0xED26FF3A.toInt())
        output.littleShort(1)
        output.littleShort(0)
        output.littleShort(28)
        output.littleShort(12)
        output.littleInt(BLOCK_BYTES)
        output.littleInt(4)
        output.littleInt(4)
        output.littleInt(0)

        output.chunk(0xCAC1, 1, 12 + BLOCK_BYTES)
        output.write(ByteArray(BLOCK_BYTES) { 0x7a })
        output.chunk(0xCAC2, 1, 16)
        output.write(byteArrayOf(1, 2, 3, 4))
        output.chunk(0xCAC3, 2, 12)
        output.chunk(0xCAC4, 0, 16)
        output.littleInt(0)
    }.toByteArray()

    private fun ByteArrayOutputStream.chunk(type: Int, blocks: Int, bytes: Int) {
        littleShort(type)
        littleShort(0)
        littleInt(blocks)
        littleInt(bytes)
    }

    private fun ByteArrayOutputStream.littleShort(value: Int) {
        write(value and 0xff)
        write((value ushr 8) and 0xff)
    }

    private fun ByteArrayOutputStream.littleInt(value: Int) {
        littleShort(value)
        littleShort(value ushr 16)
    }

    private fun temporaryFile(): File = File.createTempFile("andock-sparse-", ".ext4").also {
        it.delete()
    }

    private fun sha256(value: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(value)
        .joinToString("") { "%02x".format(it) }

    private companion object {
        const val BLOCK_BYTES = 4096
    }
}
