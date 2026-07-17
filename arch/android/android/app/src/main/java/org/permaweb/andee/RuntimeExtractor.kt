package org.permaweb.andee

import android.content.Context
import android.util.Log
import java.io.DataInputStream
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.zip.ZipInputStream

class RuntimeExtractor(private val context: Context) {
    fun extractIfNeeded(): File {
        val root = AndeePaths.runtimeRoot(context)
        val digest = runtimeZipSha256()
        val marker = AndeePaths.runtimeZipMarker(context)
        if (root.isDirectory && marker.isFile && marker.readText() == digest) {
            Log.i(TAG, "runtime ready at ${root.absolutePath}")
            return root
        }

        val tmp = File(context.noBackupFilesDir, "andee-runtime.tmp")
        tmp.deleteRecursively()
        tmp.mkdirs()
        val expandedDigests = mutableMapOf<String, String>()
        ZipInputStream(context.assets.open(RUNTIME_ZIP)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val outputName = if (entry.name.endsWith(ANDROID_SPARSE_SUFFIX)) {
                    entry.name.removeSuffix(ANDROID_SPARSE_SUFFIX)
                } else {
                    entry.name
                }
                val out = File(tmp, outputName)
                val canonicalRoot = tmp.canonicalFile.toPath()
                val canonicalOut = out.canonicalFile.toPath()
                require(canonicalOut.startsWith(canonicalRoot)) {
                    "runtime zip entry escapes destination: ${entry.name}"
                }
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    require(!out.exists()) { "duplicate runtime output: $outputName" }
                    if (entry.name.endsWith(ANDROID_SPARSE_SUFFIX)) {
                        expandedDigests[outputName] = expandAndroidSparseImage(zip, out)
                    } else {
                        out.outputStream().use { output -> zip.copyTo(output) }
                    }
                }
                zip.closeEntry()
            }
        }
        verifyExpandedImages(tmp, expandedDigests)

        marker.parentFile?.mkdirs()
        File(tmp, ".andee-runtime.sha256").writeText(digest)
        root.deleteRecursively()
        if (!tmp.renameTo(root)) {
            throw IllegalStateException("failed to install runtime atomically")
        }
        Log.i(TAG, "runtime extracted to ${root.absolutePath}")
        return root
    }

    private fun expandAndroidSparseImage(input: ZipInputStream, output: File): String {
        val data = DataInputStream(input)
        val digest = MessageDigest.getInstance("SHA-256")
        val magic = data.readLittleInt()
        require(magic == ANDROID_SPARSE_MAGIC) { "invalid Android sparse image magic" }
        val major = data.readLittleShort()
        data.readLittleShort()
        require(major == ANDROID_SPARSE_MAJOR) { "unsupported Android sparse image version" }
        val fileHeaderBytes = data.readLittleShort()
        val chunkHeaderBytes = data.readLittleShort()
        val blockBytes = data.readLittleInt()
        val totalBlocks = data.readLittleInt()
        val totalChunks = data.readLittleInt()
        data.readLittleInt()
        require(fileHeaderBytes >= ANDROID_SPARSE_FILE_HEADER_BYTES)
        require(chunkHeaderBytes >= ANDROID_SPARSE_CHUNK_HEADER_BYTES)
        require(blockBytes in 4096..(1024 * 1024) && blockBytes.countOneBits() == 1)
        require(totalBlocks > 0 && totalChunks > 0)
        data.skipExactly(fileHeaderBytes - ANDROID_SPARSE_FILE_HEADER_BYTES)

        try {
            RandomAccessFile(output, "rw").use { raw ->
                val logicalBytes = Math.multiplyExact(totalBlocks.toLong(), blockBytes.toLong())
                raw.setLength(logicalBytes)
                var emittedBlocks = 0L
                repeat(totalChunks) {
                    val type = data.readLittleShort()
                    data.readLittleShort()
                    val chunkBlocks = data.readLittleInt()
                    val chunkBytes = data.readLittleInt()
                    require(chunkBlocks >= 0)
                    data.skipExactly(chunkHeaderBytes - ANDROID_SPARSE_CHUNK_HEADER_BYTES)
                    val payloadBytes = chunkBytes - chunkHeaderBytes
                    val expandedBytes = Math.multiplyExact(chunkBlocks.toLong(), blockBytes.toLong())
                    require(emittedBlocks + chunkBlocks <= totalBlocks.toLong())
                    when (type) {
                        ANDROID_SPARSE_RAW_CHUNK -> {
                            require(payloadBytes.toLong() == expandedBytes)
                            copyExactly(data, raw, digest, expandedBytes)
                        }
                        ANDROID_SPARSE_FILL_CHUNK -> {
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
                        ANDROID_SPARSE_DONT_CARE_CHUNK -> {
                            require(payloadBytes == 0)
                            raw.seek(raw.filePointer + expandedBytes)
                            digestZeros(digest, expandedBytes)
                        }
                        ANDROID_SPARSE_CRC_CHUNK -> {
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
                raw.fd.sync()
            }
        } catch (failure: Throwable) {
            output.delete()
            throw failure
        }
        return digest.digest().toHex()
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

    private fun verifyExpandedImages(root: File, expandedDigests: Map<String, String>) {
        if (expandedDigests.isEmpty()) return
        val manifest = File(root, ANDOCK_TEMPLATE_MANIFEST)
        require(manifest.isFile) { "missing Andock template manifest" }
        val expected = org.json.JSONObject(manifest.readText()).getString("image-sha256")
        val actual = expandedDigests[ANDOCK_TEMPLATE]
            ?: error("missing expanded Andock template digest")
        require(actual == expected) { "Andock template digest mismatch" }
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

    private fun runtimeZipSha256(): String {
        val md = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        context.assets.open(RUNTIME_ZIP).use { input ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                md.update(buffer, 0, read)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "RuntimeExtractor"
        private const val RUNTIME_ZIP = "andee-runtime.zip"
        private const val ANDROID_SPARSE_SUFFIX = ".simg"
        private const val ANDROID_SPARSE_MAGIC = 0xED26FF3A.toInt()
        private const val ANDROID_SPARSE_MAJOR = 1
        private const val ANDROID_SPARSE_FILE_HEADER_BYTES = 28
        private const val ANDROID_SPARSE_CHUNK_HEADER_BYTES = 12
        private const val ANDROID_SPARSE_RAW_CHUNK = 0xCAC1
        private const val ANDROID_SPARSE_FILL_CHUNK = 0xCAC2
        private const val ANDROID_SPARSE_DONT_CARE_CHUNK = 0xCAC3
        private const val ANDROID_SPARSE_CRC_CHUNK = 0xCAC4
        private const val DIGEST_ZERO_BUFFER_BYTES = 1024 * 1024
        private const val ANDOCK_TEMPLATE =
            "execution/andock/andock-ubuntu-arm64.ext4"
        private const val ANDOCK_TEMPLATE_MANIFEST =
            "execution/andock/andock-ubuntu-arm64.ext4.manifest.json"
    }
}
