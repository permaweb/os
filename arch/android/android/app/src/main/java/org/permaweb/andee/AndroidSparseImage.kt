package org.permaweb.andee

import java.io.DataInputStream
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest

internal data class ExpandedSparseImage(
    val bytes: Long,
    val sha256: String,
)

internal object AndroidSparseImage {
    fun expand(input: InputStream, output: File): ExpandedSparseImage {
        val data = DataInputStream(input)
        val digest = MessageDigest.getInstance("SHA-256")
        val magic = data.readLittleInt()
        require(magic == MAGIC) { "invalid Android sparse image magic" }
        val major = data.readLittleShort()
        data.readLittleShort()
        require(major == MAJOR_VERSION) { "unsupported Android sparse image version" }
        val fileHeaderBytes = data.readLittleShort()
        val chunkHeaderBytes = data.readLittleShort()
        val blockBytes = data.readLittleInt()
        val totalBlocks = data.readLittleInt()
        val totalChunks = data.readLittleInt()
        data.readLittleInt()
        require(fileHeaderBytes >= FILE_HEADER_BYTES)
        require(chunkHeaderBytes >= CHUNK_HEADER_BYTES)
        require(blockBytes in 4096..(1024 * 1024) && blockBytes.countOneBits() == 1)
        require(totalBlocks > 0 && totalChunks > 0)
        data.skipExactly(fileHeaderBytes - FILE_HEADER_BYTES)

        val logicalBytes = Math.multiplyExact(totalBlocks.toLong(), blockBytes.toLong())
        try {
            RandomAccessFile(output, "rw").use { raw ->
                raw.setLength(logicalBytes)
                var emittedBlocks = 0L
                repeat(totalChunks) {
                    val type = data.readLittleShort()
                    data.readLittleShort()
                    val chunkBlocks = data.readLittleInt()
                    val chunkBytes = data.readLittleInt()
                    require(chunkBlocks >= 0)
                    data.skipExactly(chunkHeaderBytes - CHUNK_HEADER_BYTES)
                    val payloadBytes = chunkBytes - chunkHeaderBytes
                    val expandedBytes = Math.multiplyExact(
                        chunkBlocks.toLong(),
                        blockBytes.toLong(),
                    )
                    require(emittedBlocks + chunkBlocks <= totalBlocks.toLong())
                    when (type) {
                        RAW_CHUNK -> {
                            require(payloadBytes.toLong() == expandedBytes)
                            copyExactly(data, raw, digest, expandedBytes)
                        }
                        FILL_CHUNK -> {
                            require(payloadBytes == Int.SIZE_BYTES)
                            val pattern = ByteArray(Int.SIZE_BYTES)
                            data.readFully(pattern)
                            if (pattern.any { it.toInt() != 0 }) {
                                val block = ByteArray(blockBytes) { pattern[it % pattern.size] }
                                repeat(chunkBlocks) {
                                    raw.write(block)
                                    digest.update(block)
                                }
                                block.fill(0)
                            } else {
                                raw.seek(raw.filePointer + expandedBytes)
                                digestZeros(digest, expandedBytes)
                            }
                            pattern.fill(0)
                        }
                        DONT_CARE_CHUNK -> {
                            require(payloadBytes == 0)
                            raw.seek(raw.filePointer + expandedBytes)
                            digestZeros(digest, expandedBytes)
                        }
                        CRC_CHUNK -> {
                            require(chunkBlocks == 0 && payloadBytes == Int.SIZE_BYTES)
                            data.skipExactly(Int.SIZE_BYTES)
                        }
                        else -> error("unsupported Android sparse chunk type: $type")
                    }
                    emittedBlocks += chunkBlocks
                }
                require(emittedBlocks == totalBlocks.toLong()) {
                    "Android sparse image block count mismatch"
                }
                require(raw.filePointer == logicalBytes) {
                    "Android sparse image output size mismatch"
                }
                require(data.read() == -1) { "trailing Android sparse image data" }
                raw.fd.sync()
            }
        } catch (failure: Throwable) {
            output.delete()
            throw failure
        }
        return ExpandedSparseImage(logicalBytes, digest.digest().toHex())
    }

    private fun copyExactly(
        input: DataInputStream,
        output: RandomAccessFile,
        digest: MessageDigest,
        bytes: Long,
    ) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var remaining = bytes
        while (remaining > 0) {
            val wanted = minOf(buffer.size.toLong(), remaining).toInt()
            input.readFully(buffer, 0, wanted)
            output.write(buffer, 0, wanted)
            digest.update(buffer, 0, wanted)
            remaining -= wanted
        }
        buffer.fill(0)
    }

    private fun digestZeros(digest: MessageDigest, bytes: Long) {
        val zeros = ByteArray(DIGEST_ZERO_BUFFER_BYTES)
        var remaining = bytes
        while (remaining > 0) {
            val length = minOf(zeros.size.toLong(), remaining).toInt()
            digest.update(zeros, 0, length)
            remaining -= length
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private fun DataInputStream.readLittleShort(): Int {
        val low = readUnsignedByte()
        return low or (readUnsignedByte() shl 8)
    }

    private fun DataInputStream.readLittleInt(): Int =
        readLittleShort() or (readLittleShort() shl 16)

    private fun DataInputStream.skipExactly(bytes: Int) {
        require(bytes >= 0)
        var remaining = bytes
        while (remaining > 0) {
            val skipped = skipBytes(remaining)
            require(skipped > 0) { "truncated Android sparse image" }
            remaining -= skipped
        }
    }

    private const val MAGIC = 0xED26FF3A.toInt()
    private const val MAJOR_VERSION = 1
    private const val FILE_HEADER_BYTES = 28
    private const val CHUNK_HEADER_BYTES = 12
    private const val RAW_CHUNK = 0xCAC1
    private const val FILL_CHUNK = 0xCAC2
    private const val DONT_CARE_CHUNK = 0xCAC3
    private const val CRC_CHUNK = 0xCAC4
    private const val DIGEST_ZERO_BUFFER_BYTES = 1024 * 1024
}
