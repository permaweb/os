package org.permaweb.andee

import java.net.HttpURLConnection
import java.net.URL
import java.io.ByteArrayOutputStream
import org.json.JSONObject

internal object NodeMetadataHttp {
    private const val MAX_BYTES = 512 * 1024

    fun read(url: String): NodeMetadata? {
        var connection: HttpURLConnection? = null
        return try {
            connection = URL(url).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 3000
            connection.readTimeout = 8000
            connection.setRequestProperty("accept", "application/json")
            connection.setRequestProperty("require-codec", "application/json")
            connection.setRequestProperty("accept-bundle", "true")
            if (connection.responseCode != 200) return null
            val bytes = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (output.size() <= MAX_BYTES) {
                    val count = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            if (bytes.size > MAX_BYTES) return null
            val response = JSONObject(String(bytes, Charsets.UTF_8))
            val data = when (val body = response.opt("body")) {
                is JSONObject -> if (response.has("address")) response else body
                is String -> if (response.has("address")) response else JSONObject(body)
                else -> response
            }
            val hooks = data.optJSONObject("on")?.optJSONArray("start")
            val tunnel = (0 until (hooks?.length() ?: 0)).asSequence()
                .mapNotNull { hooks?.optJSONObject(it) }
                .firstOrNull {
                    it.optString("device") == "tunnel@1.0" &&
                        it.optString("path") == "connect" && it.optInt("workers", 1) > 0
                }
            NodeMetadata(
                data.optString("address", ""),
                if (data.has("location-url")) data.optString("location-url", "") else null,
                data.optString("committer", ""),
                tunnel?.optString("peer", ""),
            )
        } catch (_: Exception) { null }
        finally { connection?.disconnect() }
    }
}
