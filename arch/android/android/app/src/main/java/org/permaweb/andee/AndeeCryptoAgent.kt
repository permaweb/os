package org.permaweb.andee

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Build
import android.os.Debug
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.math.BigInteger
import java.net.SocketException
import java.security.MessageDigest
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.atomic.AtomicBoolean

class AndeeCryptoAgent(private val context: Context) : AutoCloseable {
    private val running = AtomicBoolean(false)
    private var thread: Thread? = null
    private var listenerSocket: LocalSocket? = null
    private var serverSocket: LocalServerSocket? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        AndeePaths.runDir(context).mkdirs()
        thread = Thread(::serve, "AndeeCryptoAgent").also { it.start() }
    }

    override fun close() {
        running.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        try {
            listenerSocket?.close()
        } catch (_: Exception) {
        }
        AndeePaths.cryptoSocketFile(context).delete()
        thread?.interrupt()
        thread = null
    }

    fun policyStatus(): JSONObject = policySnapshot()

    private fun serve() {
        val socketFile = AndeePaths.cryptoSocketFile(context)
        try {
            socketFile.delete()
            val listener = LocalSocket()
            listener.bind(
                LocalSocketAddress(
                    socketFile.absolutePath,
                    LocalSocketAddress.Namespace.FILESYSTEM,
                ),
            )
            listenerSocket = listener
            val server = LocalServerSocket(listener.fileDescriptor)
            serverSocket = server
            Log.i(TAG, "crypto agent listening at ${socketFile.absolutePath}")
            while (running.get()) {
                val client = try {
                    server.accept()
                } catch (exc: Exception) {
                    if (running.getAndSet(false)) {
                        Log.w(TAG, "accept failed; stopping crypto agent listener", exc)
                    }
                    break
                }
                Thread { handle(client) }.start()
            }
            server.close()
        } finally {
            serverSocket = null
            listenerSocket = null
            socketFile.delete()
        }
    }

    private fun handle(socket: android.net.LocalSocket) {
        var payload = ByteArray(0)
        var responseBytes = ByteArray(0)
        try {
            val input = DataInputStream(socket.inputStream)
            val output = DataOutputStream(socket.outputStream)
            val length = input.readInt()
            require(length in 1..(1024 * 1024)) { "bad frame length $length" }
            payload = ByteArray(length)
            input.readFully(payload)
            val response = dispatch(JSONObject(String(payload, Charsets.UTF_8)))
            responseBytes = response.toString().toByteArray(Charsets.UTF_8)
            output.writeInt(responseBytes.size)
            output.write(responseBytes)
            output.flush()
        } catch (exc: SocketException) {
            Log.w(TAG, "socket closed", exc)
        } catch (exc: Exception) {
            Log.w(TAG, "agent request failed", exc)
        } finally {
            payload.fill(0)
            responseBytes.fill(0)
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun dispatch(request: JSONObject): JSONObject {
        val action = request.optString("action")
        val policy = policySnapshot()
        val accepted = policy.optBoolean("accepted", false)
        val body = JSONObject()
            .put("accepted", accepted)
            .put("supported", true)
            .put("verdict", if (accepted) "accepted" else "policy-failure")
            .put("policy-snapshot", policy)

        when (action) {
            "policy-status" -> Unit
            "sign-evidence" -> {
                val payload = request.optJSONObject("payload")
                val subjectId = payload
                    ?.optString("evidence-subject-id")
                    .orEmpty()
                val signingResult = runCatching { signEvidenceSubject(subjectId) }
                signingResult.onSuccess { signing ->
                    body.put("attestation-challenge-subject", signing.attestationSubject)
                    body.put("keystore-signature", signing.signature)
                    body.put("android-attestation-cert-chain", signing.certificateChain)
                    body.put("key-security-level", signing.securityLevel)
                }.onFailure { exc ->
                    body.put("accepted", false)
                    body.put("verdict", "signing-unavailable")
                    body.put("attestation-challenge-subject", subjectId)
                    body.put("keystore-signature", "")
                    body.put("android-attestation-cert-chain", org.json.JSONArray())
                    body.put("key-security-level", "unavailable")
                    body.put(
                        "signing-error",
                        JSONObject()
                            .put("class", exc.javaClass.simpleName)
                            .put("message", exc.message ?: ""),
                    )
                }
            }
            "verify-evidence" -> {
                val verification = verifyEvidence(request.optJSONObject("payload"))
                body.put("verified", accepted && verification.verified)
                body.put("verifier-checks", verification.checks)
            }
            else -> body.put("error", "unknown-action")
        }

        return JSONObject().put("status", "ok").put("body", body)
    }

    private fun policySnapshot(): JSONObject {
        val appInfo = context.applicationInfo
        val debuggable = (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val adbEnabled = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1
        } catch (_: Exception) {
            true
        }
        val tracerPid = tracerPid()
        val releaseDigest = releaseDigest()
        val localAccepted = !BuildConfig.DEBUG &&
            !debuggable &&
            !Debug.isDebuggerConnected() &&
            tracerPid == 0 &&
            !adbEnabled
        val hardware = androidAttestationPolicySnapshot()
        val accepted = localAccepted && hardware.optBoolean("accepted", false)
        return JSONObject()
            .put("accepted", accepted)
            .put("local-policy-accepted", localAccepted)
            .put("package-name", context.packageName)
            .put("version-name", BuildConfig.VERSION_NAME)
            .put("version-code", BuildConfig.VERSION_CODE)
            .put("release-digest", releaseDigest)
            .put("signing-certificate-digests", signingCertificateDigests())
            .put("build-debug", BuildConfig.DEBUG)
            .put("app-debuggable", debuggable)
            .put("debugger-attached", Debug.isDebuggerConnected())
            .put("tracer-pid", tracerPid)
            .put("adb-enabled", adbEnabled)
            .put("sdk-int", Build.VERSION.SDK_INT)
            .put("security-patch", Build.VERSION.SECURITY_PATCH)
            .put("min-os-patch-level", BuildConfig.MIN_OS_PATCH_LEVEL)
            .put("min-vendor-patch-level", BuildConfig.MIN_VENDOR_PATCH_LEVEL)
            .put("min-boot-patch-level", BuildConfig.MIN_BOOT_PATCH_LEVEL)
            .put("bootloader", Build.BOOTLOADER)
            .put("device", Build.DEVICE)
            .put("manufacturer", Build.MANUFACTURER)
            .put("android-attestation", hardware)
    }

    private fun androidAttestationPolicySnapshot(): JSONObject {
        return try {
            ensureAndroidKey()
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val certs = keyStore.getCertificateChain(KEY_ALIAS)
                .orEmpty()
                .filterIsInstance<X509Certificate>()
            val chainOk = verifyCertificateChain(certs)
            val rootTrusted = certs.lastOrNull()?.encoded?.let { root ->
                attestationRootFingerprints().contains(sha256(root).toList())
            } ?: false
            val attestation = certs.firstOrNull()
                ?.getExtensionValue(ANDROID_ATTESTATION_OID)
                ?.let { parseAttestationExtension(it) }
            val attestationAppId = attestation?.attestationApplicationId
            val challengeOk = attestation?.challenge?.contentEquals(enrollmentChallenge()) == true
            val keySecurityAccepted =
                attestation?.keyMintSecurityLevel == SECURITY_TEE ||
                    attestation?.keyMintSecurityLevel == SECURITY_STRONGBOX
            val bootAccepted =
                attestation?.deviceLocked == true &&
                    attestation.verifiedBootState == VERIFIED_BOOT_VERIFIED
            val appIdAccepted = attestationApplicationAccepted(attestationAppId)
            val patchAccepted =
                (attestation?.osPatchLevel ?: 0) >= BuildConfig.MIN_OS_PATCH_LEVEL &&
                    (attestation?.vendorPatchLevel ?: 0) >= BuildConfig.MIN_VENDOR_PATCH_LEVEL &&
                    (attestation?.bootPatchLevel ?: 0) >= BuildConfig.MIN_BOOT_PATCH_LEVEL
            JSONObject()
                .put(
                    "accepted",
                    chainOk && rootTrusted && challengeOk &&
                        keySecurityAccepted && bootAccepted && appIdAccepted && patchAccepted,
                )
                .put("chain-signatures-valid", chainOk)
                .put("root-trusted", rootTrusted)
                .put("challenge-valid", challengeOk)
                .put("attestation-application-valid", appIdAccepted)
                .put("keymint-security-level", securityLevelName(attestation?.keyMintSecurityLevel))
                .put("device-locked", attestation?.deviceLocked ?: false)
                .put("verified-boot-state", verifiedBootStateName(attestation?.verifiedBootState))
                .put("verified-boot-key", attestation?.verifiedBootKey ?: "")
                .put("verified-boot-hash", attestation?.verifiedBootHash ?: "")
                .put("os-patch-level", attestation?.osPatchLevel ?: 0)
                .put("vendor-patch-level", attestation?.vendorPatchLevel ?: 0)
                .put("boot-patch-level", attestation?.bootPatchLevel ?: 0)
                .put("attestation-application-id", attestationAppId ?: JSONObject())
        } catch (exc: Exception) {
            JSONObject()
                .put("accepted", false)
                .put("error", exc.javaClass.simpleName)
                .put("message", exc.message ?: "")
        }
    }

    private fun tracerPid(): Int {
        return try {
            File("/proc/self/status").readLines()
                .firstOrNull { it.startsWith("TracerPid:") }
                ?.substringAfter(":")
                ?.trim()
                ?.toIntOrNull() ?: 0
        } catch (_: Exception) {
            -1
        }
    }

    private fun releaseDigest(): String {
        val packageInfo = context.packageManager.getPackageInfo(
            context.packageName,
            android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES,
        )
        val signers = packageInfo.signingInfo?.apkContentsSigners ?: emptyArray()
        val md = MessageDigest.getInstance("SHA-256")
        signers.forEach { md.update(it.toByteArray()) }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun signingCertificateDigests(): JSONObject {
        val packageInfo = context.packageManager.getPackageInfo(
            context.packageName,
            android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES,
        )
        val signers = packageInfo.signingInfo?.apkContentsSigners ?: emptyArray()
        return JSONObject().also { out ->
            signers.forEachIndexed { index, signer ->
                out.put(index.toString(), base64(sha256(signer.toByteArray())))
            }
        }
    }

    private fun attestationApplicationAccepted(appId: JSONObject?): Boolean {
        if (appId == null) return false
        val packageMatches = jsonObjectValues(appId.opt("package-infos")).any { item ->
            (item as? JSONObject)?.optString("package-name") == context.packageName
        }
        val expectedDigests = jsonStringSet(signingCertificateDigests())
        val attestedDigests = jsonStringSet(appId.opt("signature-digests"))
        return packageMatches && expectedDigests.isNotEmpty() &&
            attestedDigests.intersect(expectedDigests).isNotEmpty()
    }

    private fun jsonStringSet(values: Any?): Set<String> {
        return jsonObjectValues(values)
            .mapNotNull { item -> (item as? String)?.takeIf { it.isNotBlank() } }
            .toSet()
    }

    private fun jsonObjectValues(values: Any?): List<Any> {
        return when (values) {
            is JSONArray -> (0 until values.length()).mapNotNull { values.opt(it) }
            is JSONObject -> values.keys().asSequence().mapNotNull { values.opt(it) }.toList()
            else -> emptyList()
        }
    }

    private fun signEvidenceSubject(subjectId: String): SigningResult {
        ensureAndroidKey()
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val privateKey = keyStore.getKey(KEY_ALIAS, null) as java.security.PrivateKey
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(subjectId.toByteArray(Charsets.UTF_8))
        val certs = keyStore.getCertificateChain(KEY_ALIAS).orEmpty()
        val chain = JSONObject()
        certs.forEachIndexed { index, cert -> chain.put(index.toString(), base64(cert.encoded)) }
        val securityLevel = certs.firstOrNull()
            ?.let { it as? X509Certificate }
            ?.let { cert ->
                try {
                    parseAttestationExtension(cert.getExtensionValue(ANDROID_ATTESTATION_OID))
                        .keyMintSecurityLevel
                } catch (_: Exception) {
                    null
                }
            }
        return SigningResult(
            attestationSubject = enrollmentChallengeSubject(),
            signature = base64(signature.sign()),
            certificateChain = chain,
            securityLevel = securityLevelName(securityLevel),
        )
    }

    private fun ensureAndroidKey() {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) return
        generateAndroidKey(strongBox = true)
    }

    private fun generateAndroidKey(strongBox: Boolean) {
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            ANDROID_KEYSTORE,
        )
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(false)
            .setAttestationChallenge(enrollmentChallenge())
        if (Build.VERSION.SDK_INT >= 28 && strongBox) {
            builder.setIsStrongBoxBacked(true)
        }
        try {
            generator.initialize(builder.build())
            generator.generateKeyPair()
        } catch (exc: StrongBoxUnavailableException) {
            Log.w(TAG, "StrongBox unavailable; falling back to TEE-backed Keystore", exc)
            generateAndroidKey(strongBox = false)
        }
    }

    private fun enrollmentChallenge(): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(
            enrollmentChallengeSubject().toByteArray(Charsets.UTF_8),
        )
    }

    private fun enrollmentChallengeSubject(): String {
        return JSONObject()
            .put("type", "andee-android-enrollment-subject")
            .put("version", "1.0")
            .put("package-name", context.packageName)
            .put("release-digest", releaseDigest())
            .put("measurement-device", "andee@1.0")
            .toString()
    }

    private fun base64(bytes: ByteArray): String {
        return android.util.Base64.encodeToString(
            bytes,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP,
        )
    }

    private fun base64Decode(value: String): ByteArray {
        return android.util.Base64.decode(
            value,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP,
        )
    }

    private fun verifyEvidence(payload: JSONObject?): VerificationResult {
        val checks = org.json.JSONArray()
        fun record(name: String, ok: Boolean, detail: Any? = null) {
            val item = JSONObject()
                .put("name", name)
                .put("ok", ok)
                .put("severity", "core")
            if (detail != null) item.put("detail", detail)
            checks.put(item)
        }

        val measurement = payload?.optJSONObject("measurement")
        val evidence = payload?.optJSONObject("evidence")
            ?: measurement?.optJSONObject("evidence")
            ?: JSONObject()
        val policy = evidence.optJSONObject("policy-snapshot") ?: JSONObject()
        val subjectId = evidence.optString("evidence-subject-id", "")
        val certs = parseCertificateChain(evidence.opt("android-attestation-cert-chain"))

        record("certificate chain present", certs.isNotEmpty())
        record("evidence-subject-id present", subjectId.length > 20)
        record(
            "evidence policy accepted",
            policy.optBoolean("accepted", false) || evidence.optBoolean("accepted", false),
            policy,
        )
        record("package identity matches", policy.optString("package-name") == context.packageName)

        val chainOk = verifyCertificateChain(certs)
        record("certificate chain signatures validate", chainOk)

        val rootTrusted = certs.lastOrNull()?.encoded?.let { root ->
            attestationRootFingerprints().contains(sha256(root).toList())
        } ?: false
        record("certificate chain roots in Android attestation trust bundle", rootTrusted)

        val signatureOk = try {
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(certs.first().publicKey)
            verifier.update(subjectId.toByteArray(Charsets.UTF_8))
            verifier.verify(base64Decode(evidence.optString("keystore-signature", "")))
        } catch (_: Exception) {
            false
        }
        record("keystore signature verifies evidence subject id", signatureOk)

        val attestation = try {
            certs.firstOrNull()?.getExtensionValue(ANDROID_ATTESTATION_OID)?.let {
                parseAttestationExtension(it)
            }
        } catch (_: Exception) {
            null
        }
        record("Android attestation extension parses", attestation != null)
        val challengeSubject = evidence.optString("attestation-challenge-subject", "")
        val challengeOk = attestation?.challenge?.contentEquals(
            sha256(challengeSubject.toByteArray(Charsets.UTF_8)),
        ) == true
        record("attestation challenge binds enrollment subject", challengeOk)
        val securityLevelOk = when (evidence.optString("key-security-level", "")) {
            "STRONGBOX" -> attestation?.keyMintSecurityLevel == SECURITY_STRONGBOX
            "TEE" -> attestation?.keyMintSecurityLevel == SECURITY_TEE
            "SOFTWARE" -> attestation?.keyMintSecurityLevel == SECURITY_SOFTWARE
            else -> false
        }
        record("reported key security level matches attestation", securityLevelOk)
        record(
            "key security level is hardware-backed",
            attestation?.keyMintSecurityLevel == SECURITY_TEE ||
                attestation?.keyMintSecurityLevel == SECURITY_STRONGBOX,
            attestation?.keyMintSecurityLevel?.let { securityLevelName(it) },
        )
        record(
            "attestation application id matches package signing",
            attestationApplicationAccepted(attestation?.attestationApplicationId),
            attestation?.attestationApplicationId,
        )
        record(
            "device bootloader is locked",
            attestation?.deviceLocked == true,
            verifiedBootStateName(attestation?.verifiedBootState),
        )
        record(
            "verified boot state is verified",
            attestation?.verifiedBootState == VERIFIED_BOOT_VERIFIED,
            verifiedBootStateName(attestation?.verifiedBootState),
        )
        val patchAccepted =
            (attestation?.osPatchLevel ?: 0) >= BuildConfig.MIN_OS_PATCH_LEVEL &&
                (attestation?.vendorPatchLevel ?: 0) >= BuildConfig.MIN_VENDOR_PATCH_LEVEL &&
                (attestation?.bootPatchLevel ?: 0) >= BuildConfig.MIN_BOOT_PATCH_LEVEL
        record(
            "patch floors satisfied",
            patchAccepted,
            JSONObject()
                .put("os-patch-level", attestation?.osPatchLevel ?: 0)
                .put("vendor-patch-level", attestation?.vendorPatchLevel ?: 0)
                .put("boot-patch-level", attestation?.bootPatchLevel ?: 0),
        )

        var verified = true
        for (i in 0 until checks.length()) {
            verified = verified && checks.getJSONObject(i).optBoolean("ok", false)
        }
        return VerificationResult(verified, checks)
    }

    private fun parseCertificateChain(chain: Any?): List<X509Certificate> {
        val factory = CertificateFactory.getInstance("X.509")
        val encoded = when (chain) {
            is JSONArray -> (0 until chain.length()).mapNotNull { index ->
                chain.optString(index).takeIf { it.isNotBlank() }
            }
            is JSONObject -> chain.keys().asSequence()
                .filter { it.all(Char::isDigit) }
                .sortedBy { it.toInt() }
                .mapNotNull { key -> chain.optString(key).takeIf { it.isNotBlank() } }
                .toList()
            else -> emptyList()
        }
        return encoded.map { item ->
            val bytes = base64Decode(item)
            factory.generateCertificate(ByteArrayInputStream(bytes)) as X509Certificate
        }
    }

    private fun verifyCertificateChain(certs: List<X509Certificate>): Boolean {
        if (certs.isEmpty()) return false
        return try {
            for (i in 0 until certs.size - 1) {
                certs[i].verify(certs[i + 1].publicKey)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun attestationRootFingerprints(): Set<List<Byte>> {
        val factory = CertificateFactory.getInstance("X.509")
        return try {
            context.assets.open(ANDROID_ATTESTATION_ROOTS).use { input ->
                factory.generateCertificates(input)
                    .filterIsInstance<X509Certificate>()
                    .map { sha256(it.encoded).toList() }
                    .toSet()
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun sha256(bytes: ByteArray): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(bytes)
    }

    private fun parseAttestationExtension(extensionValue: ByteArray): AttestationDetails {
        val wrapped = DerReader(extensionValue).read()
        require(wrapped.tagClass == DER_UNIVERSAL && wrapped.tag == DER_OCTET_STRING)
        val keyDescription = DerReader(wrapped.value).read()
        require(keyDescription.tagClass == DER_UNIVERSAL && keyDescription.tag == DER_SEQUENCE)
        val reader = DerReader(keyDescription.value)
        reader.readInteger()
        reader.readEnumerated()
        reader.readInteger()
        val keyMintSecurityLevel = reader.readEnumerated()
        val challenge = reader.readOctetString()
        reader.readOctetString()
        val software = reader.readSequence()
        val softwareAuth = parseAuthorizationList(software)
        val hardware = reader.readSequence()
        val hardwareAuth = parseAuthorizationList(hardware)
        val root = hardwareAuth[ROOT_OF_TRUST_TAG]?.let { parseRootOfTrust(it) }
        return AttestationDetails(
            keyMintSecurityLevel = keyMintSecurityLevel,
            challenge = challenge,
            deviceLocked = root?.deviceLocked,
            verifiedBootState = root?.verifiedBootState,
            verifiedBootKey = root?.verifiedBootKey,
            verifiedBootHash = root?.verifiedBootHash,
            osPatchLevel = hardwareAuth[OS_PATCH_LEVEL_TAG]?.asInteger(),
            vendorPatchLevel = hardwareAuth[VENDOR_PATCH_LEVEL_TAG]?.asInteger(),
            bootPatchLevel = hardwareAuth[BOOT_PATCH_LEVEL_TAG]?.asInteger(),
            attestationApplicationId =
                softwareAuth[ATTESTATION_APPLICATION_ID_TAG]
                    ?.let { parseAttestationApplicationId(it) },
        )
    }

    private fun parseAuthorizationList(sequence: DerValue): Map<Int, DerValue> {
        require(sequence.tagClass == DER_UNIVERSAL && sequence.tag == DER_SEQUENCE)
        val out = mutableMapOf<Int, DerValue>()
        val reader = DerReader(sequence.value)
        while (reader.hasRemaining()) {
            val explicit = reader.read()
            if (explicit.tagClass == DER_CONTEXT_SPECIFIC) {
                out[explicit.tag] = DerReader(explicit.value).read()
            }
        }
        return out
    }

    private fun parseRootOfTrust(value: DerValue): RootOfTrust {
        require(value.tagClass == DER_UNIVERSAL && value.tag == DER_SEQUENCE)
        val reader = DerReader(value.value)
        val verifiedBootKey = base64(reader.readOctetString())
        val deviceLocked = reader.readBoolean()
        val verifiedBootState = reader.readEnumerated()
        val verifiedBootHash =
            if (reader.hasRemaining()) base64(reader.readOctetString()) else null
        return RootOfTrust(verifiedBootKey, deviceLocked, verifiedBootState, verifiedBootHash)
    }

    private fun parseAttestationApplicationId(value: DerValue): JSONObject {
        require(value.tagClass == DER_UNIVERSAL && value.tag == DER_OCTET_STRING)
        val sequence = DerReader(value.value).readSequence()
        val reader = DerReader(sequence.value)
        val packageInfos = reader.readSet()
        val signatureDigests = reader.readSet()
        return JSONObject()
            .put("package-infos", parseAttestationPackageInfos(packageInfos))
            .put("signature-digests", parseOctetStringSet(signatureDigests))
    }

    private fun parseAttestationPackageInfos(value: DerValue): JSONObject {
        require(value.tagClass == DER_UNIVERSAL && value.tag == DER_SET)
        val out = JSONObject()
        val reader = DerReader(value.value)
        var index = 0
        while (reader.hasRemaining()) {
            val packageInfo = reader.readSequence()
            val packageReader = DerReader(packageInfo.value)
            val packageName = packageReader.readOctetString().toString(Charsets.UTF_8)
            val version = packageReader.readInteger()
            out.put(index.toString(), JSONObject().put("package-name", packageName).put("version", version))
            index++
        }
        return out
    }

    private fun parseOctetStringSet(value: DerValue): JSONObject {
        require(value.tagClass == DER_UNIVERSAL && value.tag == DER_SET)
        val out = JSONObject()
        val reader = DerReader(value.value)
        var index = 0
        while (reader.hasRemaining()) {
            out.put(index.toString(), base64(reader.readOctetString()))
            index++
        }
        return out
    }

    private fun DerValue.asInteger(): Int {
        require(tagClass == DER_UNIVERSAL && tag == DER_INTEGER)
        return BigInteger(value).toInt()
    }

    private fun securityLevelName(value: Int?): String {
        return when (value) {
            SECURITY_STRONGBOX -> "STRONGBOX"
            SECURITY_TEE -> "TEE"
            SECURITY_SOFTWARE -> "SOFTWARE"
            else -> "UNKNOWN"
        }
    }

    private fun verifiedBootStateName(value: Int?): String {
        return when (value) {
            VERIFIED_BOOT_VERIFIED -> "VERIFIED"
            1 -> "SELF_SIGNED"
            2 -> "UNVERIFIED"
            3 -> "FAILED"
            else -> "UNKNOWN"
        }
    }

    private class DerReader(private val data: ByteArray) {
        private var offset = 0

        fun hasRemaining(): Boolean = offset < data.size

        fun readInteger(): Int {
            val value = read()
            require(value.tagClass == DER_UNIVERSAL && value.tag == DER_INTEGER)
            return BigInteger(value.value).toInt()
        }

        fun readEnumerated(): Int {
            val value = read()
            require(value.tagClass == DER_UNIVERSAL && value.tag == DER_ENUMERATED)
            return BigInteger(value.value).toInt()
        }

        fun readBoolean(): Boolean {
            val value = read()
            require(value.tagClass == DER_UNIVERSAL && value.tag == DER_BOOLEAN)
            return value.value.any { it.toInt() != 0 }
        }

        fun readOctetString(): ByteArray {
            val value = read()
            require(value.tagClass == DER_UNIVERSAL && value.tag == DER_OCTET_STRING)
            return value.value
        }

        fun readSequence(): DerValue {
            val value = read()
            require(value.tagClass == DER_UNIVERSAL && value.tag == DER_SEQUENCE)
            return value
        }

        fun readSet(): DerValue {
            val value = read()
            require(value.tagClass == DER_UNIVERSAL && value.tag == DER_SET)
            return value
        }

        fun read(): DerValue {
            require(offset < data.size)
            val first = data[offset++].toInt() and 0xff
            val tagClass = first and 0xc0
            var tag = first and 0x1f
            if (tag == 0x1f) {
                tag = 0
                do {
                    require(offset < data.size)
                    val next = data[offset++].toInt() and 0xff
                    tag = (tag shl 7) or (next and 0x7f)
                } while (next and 0x80 != 0)
            }
            require(offset < data.size)
            val firstLength = data[offset++].toInt() and 0xff
            val length = if (firstLength and 0x80 == 0) {
                firstLength
            } else {
                val count = firstLength and 0x7f
                require(count in 1..4 && offset + count <= data.size)
                var parsed = 0
                repeat(count) {
                    parsed = (parsed shl 8) or (data[offset++].toInt() and 0xff)
                }
                parsed
            }
            require(offset + length <= data.size)
            val value = data.copyOfRange(offset, offset + length)
            offset += length
            return DerValue(tagClass, tag, value)
        }
    }

    private data class SigningResult(
        val attestationSubject: String,
        val signature: String,
        val certificateChain: JSONObject,
        val securityLevel: String,
    )

    private data class VerificationResult(
        val verified: Boolean,
        val checks: org.json.JSONArray,
    )

    private data class AttestationDetails(
        val keyMintSecurityLevel: Int,
        val challenge: ByteArray,
        val deviceLocked: Boolean?,
        val verifiedBootState: Int?,
        val verifiedBootKey: String?,
        val verifiedBootHash: String?,
        val osPatchLevel: Int?,
        val vendorPatchLevel: Int?,
        val bootPatchLevel: Int?,
        val attestationApplicationId: JSONObject?,
    )

    private data class RootOfTrust(
        val verifiedBootKey: String,
        val deviceLocked: Boolean,
        val verifiedBootState: Int,
        val verifiedBootHash: String?,
    )

    private data class DerValue(
        val tagClass: Int,
        val tag: Int,
        val value: ByteArray,
    )

    companion object {
        private const val TAG = "AndeeCryptoAgent"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "andee_android_attestation_v1"
        private const val ANDROID_ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17"
        private const val ANDROID_ATTESTATION_ROOTS = "android-attestation-roots.pem"
        private const val ATTESTATION_APPLICATION_ID_TAG = 709
        private const val DER_UNIVERSAL = 0x00
        private const val DER_CONTEXT_SPECIFIC = 0x80
        private const val DER_SEQUENCE = 16
        private const val DER_SET = 17
        private const val DER_INTEGER = 0x02
        private const val DER_BOOLEAN = 0x01
        private const val DER_ENUMERATED = 0x0a
        private const val DER_OCTET_STRING = 0x04
        private const val SECURITY_SOFTWARE = 0
        private const val SECURITY_TEE = 1
        private const val SECURITY_STRONGBOX = 2
        private const val VERIFIED_BOOT_VERIFIED = 0
        private const val ROOT_OF_TRUST_TAG = 704
        private const val OS_PATCH_LEVEL_TAG = 706
        private const val VENDOR_PATCH_LEVEL_TAG = 718
        private const val BOOT_PATCH_LEVEL_TAG = 719
    }
}
