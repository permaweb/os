package org.permaweb.andee.imageprobe;

final class NativeProbe {
    static {
        System.loadLibrary("andock_image_engine_probe");
    }

    private NativeProbe() {}

    static native String initialize(int imageFd);

    static native String verify(int imageFd);

    static native void crashAfterMutation(int imageFd);

    static native String rejectMalformed(int imageFd, int kind);

    static native String sparseCopy(int sourceFd, int destinationFd);
}
