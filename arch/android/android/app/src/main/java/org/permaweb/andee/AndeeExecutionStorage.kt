package org.permaweb.andee

import android.content.Context
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

private const val ANDOCK_HOST_FREE_RESERVE_BYTES = 512L * 1024 * 1024

/** Owns immutable-template cloning and one complete writable image per member. */
internal class AndeeExecutionStorage(
    context: Context,
    runtimeRoot: File,
    configFile: File,
) : AutoCloseable {
    private val root = AndeePaths.executionStateRoot(context)
    private val members = File(root, "members")
    private val materializer = AndeeAndockImageMaterializer(context, runtimeRoot, configFile)
    private val templateBytes = materializer.logicalBytes

    fun start() {
        require(members.mkdirs() || members.isDirectory) {
            "failed to create Andock member image directory"
        }
        Os.chmod(root.absolutePath, 0b111_000_000)
        Os.chmod(members.absolutePath, 0b111_000_000)
        members.listFiles { file -> file.name.startsWith('.') && file.name.endsWith(".tmp") }
            .orEmpty()
            .forEach { require(it.delete()) { "failed to remove incomplete member image" } }
        materializer.start()
    }

    fun open(memberId: String): ParcelFileDescriptor {
        val image = memberImage(memberId)
        if (!image.isFile) create(image, materializer.requireTemplate())
        return ParcelFileDescriptor.open(
            image,
            ParcelFileDescriptor.MODE_READ_WRITE,
        )
    }

    fun prepare(memberId: String) {
        open(memberId).close()
    }

    fun destroy(memberId: String) {
        val image = memberImage(memberId)
        if (image.exists()) {
            require(image.delete()) { "failed to delete Andock member image" }
            syncDirectory(members)
        }
    }

    override fun close() {
        materializer.close()
    }

    private fun create(image: File, template: File) {
        val templateAllocatedBytes = Math.multiplyExact(
            Os.stat(template.absolutePath).st_blocks,
            POSIX_BLOCK_BYTES,
        )
        require(templateAllocatedBytes in 1..templateBytes) {
            "invalid Andock filesystem template allocation: $templateAllocatedBytes"
        }
        require(hasAndockCreationCapacity(members.usableSpace, templateAllocatedBytes)) {
            "insufficient app-private storage for a new Andock member image"
        }
        val temporary = File(
            members,
            ".${image.name}.${randomToken()}.tmp",
        )
        try {
            ParcelFileDescriptor.open(
                template,
                ParcelFileDescriptor.MODE_READ_ONLY,
            ).use { source ->
                ParcelFileDescriptor.open(
                    temporary,
                    ParcelFileDescriptor.MODE_CREATE or
                        ParcelFileDescriptor.MODE_READ_WRITE or
                        ParcelFileDescriptor.MODE_TRUNCATE,
                ).use { destination ->
                    copySparse(source, destination, templateBytes)
                    Os.fsync(destination.fileDescriptor)
                }
            }
            Os.chmod(temporary.absolutePath, 0b110_000_000)
            Os.rename(temporary.absolutePath, image.absolutePath)
            syncDirectory(members)
        } finally {
            temporary.delete()
        }
    }

    private fun copySparse(
        source: ParcelFileDescriptor,
        destination: ParcelFileDescriptor,
        size: Long,
    ) {
        Os.ftruncate(destination.fileDescriptor, size)
        try {
            copyDataExtents(source, destination, size)
        } catch (failure: ErrnoException) {
            if (failure.errno != OsConstants.EINVAL && failure.errno != OsConstants.ENOTSUP) {
                throw failure
            }
            copyNonzeroBlocks(source, destination, size)
        }
    }

    private fun copyDataExtents(
        source: ParcelFileDescriptor,
        destination: ParcelFileDescriptor,
        size: Long,
    ) {
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        try {
            var offset = 0L
            while (offset < size) {
                val data = try {
                    Os.lseek(source.fileDescriptor, offset, SEEK_DATA)
                } catch (failure: ErrnoException) {
                    if (failure.errno == OsConstants.ENXIO) break
                    throw failure
                }
                val hole = Os.lseek(source.fileDescriptor, data, SEEK_HOLE)
                var current = data
                while (current < hole) {
                    val length = minOf(buffer.size.toLong(), hole - current).toInt()
                    val read = Os.pread(source.fileDescriptor, buffer, 0, length, current)
                    require(read > 0) { "unexpected end of Andock template" }
                    writeFully(destination, buffer, read, current)
                    current += read
                }
                offset = hole
            }
        } finally {
            buffer.fill(0)
        }
    }

    private fun copyNonzeroBlocks(
        source: ParcelFileDescriptor,
        destination: ParcelFileDescriptor,
        size: Long,
    ) {
        val buffer = ByteArray(FALLBACK_BLOCK_BYTES)
        try {
            var offset = 0L
            while (offset < size) {
                val length = minOf(buffer.size.toLong(), size - offset).toInt()
                val read = Os.pread(source.fileDescriptor, buffer, 0, length, offset)
                require(read > 0) { "unexpected end of Andock template" }
                if (buffer.hasNonzeroByte(read)) {
                    writeFully(destination, buffer, read, offset)
                }
                offset += read
            }
        } finally {
            buffer.fill(0)
        }
    }

    private fun writeFully(
        destination: ParcelFileDescriptor,
        buffer: ByteArray,
        length: Int,
        offset: Long,
    ) {
        var written = 0
        while (written < length) {
            written += Os.pwrite(
                destination.fileDescriptor,
                buffer,
                written,
                length - written,
                offset + written,
            )
        }
    }

    private fun ByteArray.hasNonzeroByte(length: Int): Boolean {
        for (index in 0 until length) {
            if (this[index].toInt() != 0) return true
        }
        return false
    }

    private fun memberImage(memberId: String): File =
        File(members, "${memberKey(memberId)}.ext4")

    private fun memberKey(memberId: String): String =
        Base64.encodeToString(
            MessageDigest.getInstance("SHA-256").digest(memberId.toByteArray()),
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        )

    private fun randomToken(): String {
        val bytes = ByteArray(12)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(
            bytes,
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        )
    }

    private fun syncDirectory(directory: File) {
        val descriptor = Os.open(
            directory.absolutePath,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC,
            0,
        )
        try {
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }

    private companion object {
        const val COPY_BUFFER_BYTES = 1024 * 1024
        const val FALLBACK_BLOCK_BYTES = 4096
        const val SEEK_DATA = 3
        const val SEEK_HOLE = 4
        const val POSIX_BLOCK_BYTES = 512L
    }
}

internal fun hasAndockCreationCapacity(available: Long, allocated: Long): Boolean =
    available >= ANDOCK_HOST_FREE_RESERVE_BYTES &&
        allocated <= available - ANDOCK_HOST_FREE_RESERVE_BYTES
