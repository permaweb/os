package org.permaweb.andee;

import android.os.ParcelFileDescriptor;

interface IAndeeExecutionWorker {
    String execute(
        String command,
        String cwd,
        int timeoutMs,
        boolean mergeError,
        in ParcelFileDescriptor image,
        in ParcelFileDescriptor input,
        in ParcelFileDescriptor output
    );
    void stop();
}
