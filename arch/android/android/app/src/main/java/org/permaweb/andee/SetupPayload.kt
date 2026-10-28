package org.permaweb.andee

import com.sparrowwallet.hummingbird.ResultType
import com.sparrowwallet.hummingbird.UR
import com.sparrowwallet.hummingbird.URDecoder
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.DataFormatException
import java.util.zip.Inflater

/**
 * A boot config handed to your node as a Blockchain Commons UR of type `bytes` whose body is the raw-DEFLATE of
 * the compact config JSON. The PermawebOS extension shows it as a loop of fountain-coded QR parts; the same
 * string also fits a single intent extra. Decoding only recovers the text: validation, reserved-key stripping
 * and staging stay with [AndeeBootConfigStore.stageNextBootConfig], exactly as for the file picker.
 */
object SetupPayload {
    const val MAX_CONFIG_BYTES = 256 * 1024

    fun fromUr(ur: UR): String {
        require(ur.type == "bytes") { "Unexpected setup code type: ${ur.type}" }
        return inflate(ur.toBytes())
    }

    /** A complete single-part UR string, e.g. from an intent extra. */
    fun fromUrString(text: String): String = fromUr(URDecoder.decode(text.trim()))

    /** Base64 or base64url of the plain config JSON, for callers that cannot easily quote JSON. */
    fun fromBase64(text: String): String {
        val compact = text.trim().replace('-', '+').replace('_', '/').filterNot { it.isWhitespace() }
        val bytes = Base64.getDecoder().decode(compact.padEnd((compact.length + 3) / 4 * 4, '='))
        require(bytes.size <= MAX_CONFIG_BYTES) { "Setup is too large" }
        return String(bytes, Charsets.UTF_8)
    }

    fun inflate(deflated: ByteArray): String {
        val inflater = Inflater(true)
        try {
            inflater.setInput(deflated)
            val out = ByteArrayOutputStream(deflated.size * 3)
            val buffer = ByteArray(8192)
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) {
                    throw DataFormatException("truncated setup code")
                }
                out.write(buffer, 0, n)
                require(out.size() <= MAX_CONFIG_BYTES) { "Setup is too large" }
            }
            return out.toString(Charsets.UTF_8.name())
        } finally {
            inflater.end()
        }
    }
}

/** Collects scanned QR parts until the fountain decoder has the whole setup. Not thread-safe; one scanner. */
class SetupScan {
    private val decoder = URDecoder()

    /** Distinct frames read so far (pure parts and fountain mixes); repeats of a looping frame don't count. */
    val acceptedParts: Int get() = decoder.processedPartsCount

    /** The number of pure fragments N, or 0 before the first part arrives. */
    val expectedParts: Int get() = decoder.expectedPartCount

    /** Indexes (0-based) of the pure fragments recovered so far. */
    val receivedIndexes: Set<Int> get() = decoder.receivedPartIndexes

    val percent: Int
        get() = when {
            decoder.result?.type == ResultType.SUCCESS -> 100
            expectedParts == 0 -> 0
            else -> (decoder.estimatedPercentComplete * 100).toInt().coerceIn(0, 99)
        }

    /** Feeds one QR text. Returns true when this part was new to the decoder. Non-UR text is ignored. */
    fun accept(text: String): Boolean {
        if (!text.trim().startsWith("ur:", ignoreCase = true)) return false
        val before = decoder.processedPartsCount
        return decoder.receivePart(text.trim()) && decoder.processedPartsCount > before
    }

    /** The decoded config text once complete, null while parts are missing. Throws if the decode failed. */
    fun result(): String? {
        val r = decoder.result ?: return null
        check(r.type == ResultType.SUCCESS) { r.error ?: "The setup code could not be read" }
        return SetupPayload.fromUr(r.ur)
    }
}
