package org.permaweb.andee

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.security.MessageDigest

object AndeeBootConfigStore {
    fun hasPending(context: Context): Boolean = pendingConfigFile(context).isFile

    fun stageNextBootConfig(context: Context, text: String) {
        parseConfigObject(text)
        writeAtomic(pendingConfigFile(context), text)
    }

    fun commitPendingForNextBoot(context: Context): Boolean = installPendingIfPresent(context)

    fun effectiveConfigFile(context: Context, baseConfig: File): File {
        require(baseConfig.isFile) { "missing base AndEE config: ${baseConfig.absolutePath}" }
        installPendingIfPresent(context)
        val active = activeConfigFile(context)
        if (!active.isFile) return baseConfig

        val activeText = active.readText(Charsets.UTF_8)
        val effective = mergeEffectiveConfig(
            base = parseConfigObject(baseConfig.readText(Charsets.UTF_8)),
            operator = parseConfigObject(activeText),
            operatorText = activeText,
        )
        val out = effectiveConfigFilePath(context)
        writeAtomic(out, effective.toString(2) + "\n")
        return out
    }

    private fun installPendingIfPresent(context: Context): Boolean {
        val pending = pendingConfigFile(context)
        if (!pending.isFile) return false
        val active = activeConfigFile(context)
        active.parentFile?.mkdirs()
        val tmp = File(active.parentFile, "${active.name}.tmp")
        pending.copyTo(tmp, overwrite = true)
        if (!tmp.renameTo(active)) {
            tmp.copyTo(active, overwrite = true)
            tmp.delete()
        }
        if (!pending.delete() && pending.exists()) {
            throw IllegalStateException("failed to consume pending boot config: ${pending.absolutePath}")
        }
        effectiveConfigFilePath(context).delete()
        return true
    }

    private fun mergeEffectiveConfig(
        base: JSONObject,
        operator: JSONObject,
        operatorText: String,
    ): JSONObject {
        val merged = deepMerge(copyObject(base), operator)
        stripPrivateBootKeys(merged)

        merged.put("measurement-device", "andee@1.0")
        merged.put("store", copyValue(base.getJSONArray("store")))
        merged.put("andee-config-source", "app-private-next-boot-config")
        merged.put("andee-operator-config-sha256", base64UrlSha256(operatorText.toByteArray(Charsets.UTF_8)))
        merged.put("andee-operator-config-bytes", operatorText.toByteArray(Charsets.UTF_8).size)
        if (operator.optBoolean("load-remote-devices", false) && !operator.has("routes")) {
            merged.remove("routes")
        }

        val on = merged.optJSONObject("on") ?: JSONObject()
        on.put("start", mergedStartHooks(base, operator))
        merged.put("on", on)
        return merged
    }

    private fun mergedStartHooks(base: JSONObject, operator: JSONObject): Any {
        val hooks = JSONArray()
        for (hook in hookList(base.optJSONObject("on")?.opt("start"))) {
            hooks.put(copyValue(hook))
        }
        for (hook in hookList(operator.optJSONObject("on")?.opt("start"))) {
            hooks.put(copyValue(hook))
        }
        return if (hooks.length() == 1) hooks.get(0) else hooks
    }

    private fun hookList(value: Any?): List<Any> {
        return when (value) {
            null -> emptyList()
            is JSONArray -> (0 until value.length()).map { value.get(it) }
            else -> listOf(value)
        }
    }

    private fun deepMerge(base: JSONObject, overlay: JSONObject): JSONObject {
        val keys = overlay.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val overlayValue = overlay.get(key)
            val baseValue = base.opt(key)
            if (baseValue is JSONObject && overlayValue is JSONObject) {
                base.put(key, deepMerge(copyObject(baseValue), overlayValue))
            } else {
                base.put(key, copyValue(overlayValue))
            }
        }
        return base
    }

    private fun parseConfigObject(text: String): JSONObject {
        val tokener = JSONTokener(text)
        val value = tokener.nextValue()
        require(value is JSONObject) { "AndEE boot config must be a JSON object" }
        require(tokener.nextClean().code == 0) { "AndEE boot config must contain exactly one JSON value" }
        return value
    }

    private fun stripPrivateBootKeys(value: JSONObject) {
        for (key in PRIVATE_BOOT_KEYS) value.remove(key)
    }

    private fun copyObject(value: JSONObject): JSONObject {
        val out = JSONObject()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out.put(key, copyValue(value.get(key)))
        }
        return out
    }

    private fun copyValue(value: Any?): Any? {
        return when (value) {
            is JSONObject -> copyObject(value)
            is JSONArray -> JSONArray().also { out ->
                for (index in 0 until value.length()) out.put(copyValue(value.get(index)))
            }
            else -> value
        }
    }

    private fun writeAtomic(file: File, text: String) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(text, Charsets.UTF_8)
        if (!tmp.renameTo(file)) {
            tmp.copyTo(file, overwrite = true)
            tmp.delete()
        }
    }

    private fun base64UrlSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return Base64.encodeToString(
            digest,
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        )
    }

    private fun configDir(context: Context): File = File(context.noBackupFilesDir, "boot-config")
    private fun pendingConfigFile(context: Context): File = File(configDir(context), "next.json")
    private fun activeConfigFile(context: Context): File = File(configDir(context), "active.json")
    private fun effectiveConfigFilePath(context: Context): File = File(configDir(context), "effective.json")

    private val PRIVATE_BOOT_KEYS = setOf(
        "priv-wallet",
        "private-key",
        "priv-key-location",
        "secret",
    )
}
