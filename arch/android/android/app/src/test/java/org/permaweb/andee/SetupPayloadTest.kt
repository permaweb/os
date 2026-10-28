package org.permaweb.andee

import com.sparrowwallet.hummingbird.UR
import com.sparrowwallet.hummingbird.UREncoder
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.Deflater
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Decodes the parts the PermawebOS extension shows (fixture written by the JS encoder, @ngraveio/bc-ur). */
class SetupPayloadTest {
    private val fixture = javaClass.getResource("/setup/full-parts.json")!!.readText()
    private val parts = Regex("\"(UR:BYTES/[^\"]+)\"").findAll(fixture).map { it.groupValues[1] }.toList()
    private val fragments = Regex("\"fragments\": (\\d+)").find(fixture)!!.groupValues[1].toInt()
    private val sha256 = Regex("\"sha256\": \"([0-9a-f]{64})\"").find(fixture)!!.groupValues[1]

    private fun sha(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        .joinToString("") { "%02x".format(it) }

    @Test
    fun pureFragmentsInOrderDecodeByteIdentical() {
        val scan = SetupScan()
        parts.take(fragments).dropLast(1).forEach { assertTrue(scan.accept(it)) }
        assertNull(scan.result())
        assertEquals(fragments, scan.expectedParts)
        assertTrue(scan.percent in 1..99)
        scan.accept(parts[fragments - 1])
        assertEquals(100, scan.percent)
        assertEquals(sha256, sha(scan.result()!!))
    }

    @Test
    fun fountainPartsRecoverSkippedFrames() {
        val scan = SetupScan()
        for (part in parts.drop(3)) {
            scan.accept(part)
            if (scan.result() != null) break
        }
        assertEquals(sha256, sha(scan.result()!!))
    }

    @Test
    fun repeatedAndForeignCodesAreIgnored() {
        val scan = SetupScan()
        assertTrue(scan.accept(parts[0]))
        assertFalse(scan.accept(parts[0]))
        assertFalse(scan.accept("https://example.invalid/not-a-setup"))
        assertEquals(1, scan.acceptedParts)
    }

    @Test
    fun lowercaseQrTextIsAccepted() {
        val scan = SetupScan()
        parts.take(fragments).forEach { scan.accept(it.lowercase()) }
        assertEquals(sha256, sha(scan.result()!!))
    }

    @Test
    fun singlePartUrAndBase64ExtrasDecode() {
        val json = """{"andee-profile-source":"test","port":8734}"""
        val deflater = Deflater(Deflater.BEST_COMPRESSION, true)
        deflater.setInput(json.toByteArray()); deflater.finish()
        val buffer = ByteArray(1024)
        val deflated = buffer.copyOf(deflater.deflate(buffer)); deflater.end()
        val single = UREncoder.encode(UR.fromBytes(deflated))
        assertEquals(json, SetupPayload.fromUrString(single))
        assertEquals(json, SetupPayload.fromBase64(Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())))
        assertEquals(json, SetupPayload.fromBase64(Base64.getEncoder().encodeToString(json.toByteArray())))
    }

    @Test(expected = Exception::class)
    fun garbageIsRejected() {
        SetupPayload.inflate(byteArrayOf(1, 2, 3, 4))
    }
}
