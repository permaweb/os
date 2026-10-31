package org.permaweb.andee

import java.net.URI
import java.util.Base64

/** Constrain the existing staging bridge to the configurator's manifest. */
internal class ConfiguratorLocation(val url: String) {
    private val root = URI(url)
    private val path = root.rawPath.trimEnd('/') + "/"
    val entryUrl: String = root.resolve(path + "index.html").toString()
    private val sandbox = if (root.host == "arweave.net") {
        val tx = path.trim('/')
        require(Regex("[A-Za-z0-9_-]{43}").matches(tx))
        base32(Base64.getUrlDecoder().decode(tx)) + ".arweave.net"
    } else null

    init {
        require(root.scheme == "https" || (root.scheme == "http" && root.host == "127.0.0.1"))
        require(!root.host.isNullOrEmpty() && root.rawUserInfo == null && root.rawQuery == null && root.rawFragment == null)
    }

    fun contains(value: String): Boolean = try {
        val target = URI(value)
        target.rawUserInfo == null && target.scheme == root.scheme &&
            target.path.split('/').none { it == "." || it == ".." } && (
            (target.host == root.host && target.port == root.port &&
                (target.rawPath == path.trimEnd('/') || target.rawPath.startsWith(path))) ||
            (sandbox != null && target.host == sandbox && target.port in listOf(-1, 443))
        )
    } catch (_: Exception) { false }

    private fun base32(bytes: ByteArray): String {
        val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        val out = StringBuilder()
        var buffer = 0
        var bits = 0
        for (byte in bytes) {
            buffer = (buffer shl 8) or (byte.toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                out.append(alphabet[(buffer shr (bits - 5)) and 31])
                bits -= 5
            }
        }
        if (bits > 0) out.append(alphabet[(buffer shl (5 - bits)) and 31])
        return out.toString()
    }
}
