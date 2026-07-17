package org.permaweb.andee.imageprobe;

import android.os.ParcelFileDescriptor;

interface IImageEngineProbe {
    String initialize(in ParcelFileDescriptor image);
    String verify(in ParcelFileDescriptor image);
    void crashAfterMutation(in ParcelFileDescriptor image);
    String rejectMalformed(in ParcelFileDescriptor image, int kind);
    int isolatedUid();
    int isolatedPid();
}
