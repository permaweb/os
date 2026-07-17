package org.permaweb.andee

import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Parcelable

/** Socket-creation result whose descriptor exists only when errno is zero. */
class AndeeSocketResult(
    val errno: Int,
    val descriptor: ParcelFileDescriptor?,
) : Parcelable {
    init {
        require(errno >= 0) { "socket errno cannot be negative" }
        require((errno == 0) == (descriptor != null)) {
            "socket descriptor must be present exactly when errno is zero"
        }
    }

    private constructor(parcel: Parcel) : this(
        parcel.readInt(),
        parcel.readTypedObject(ParcelFileDescriptor.CREATOR),
    )

    override fun writeToParcel(parcel: Parcel, flags: Int) {
        parcel.writeInt(errno)
        parcel.writeTypedObject(descriptor, flags)
    }

    override fun describeContents(): Int = descriptor?.describeContents() ?: 0

    companion object CREATOR : Parcelable.Creator<AndeeSocketResult> {
        override fun createFromParcel(parcel: Parcel): AndeeSocketResult = AndeeSocketResult(parcel)

        override fun newArray(size: Int): Array<AndeeSocketResult?> = arrayOfNulls(size)
    }
}
