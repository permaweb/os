package org.permaweb.andee

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

internal object DiscoveryQr {
    fun rowsFor(url: String): Array<BooleanArray> {
        if (url.isEmpty()) return Array(33) { BooleanArray(33) }
        val matrix = QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, 0, 0, mapOf(
            EncodeHintType.CHARACTER_SET to "UTF-8",
            EncodeHintType.MARGIN to 4,
        ))
        return Array(matrix.height) { row -> BooleanArray(matrix.width) { column -> matrix[column, row] } }
    }
}
