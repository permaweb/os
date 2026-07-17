package org.permaweb.andee;

import android.os.ParcelFileDescriptor;
import org.permaweb.andee.IAndeeNetworkBroker;

interface IAndeeExecutionWorker {
    String execute(
        String command,
        String cwd,
        int timeoutMs,
        boolean mergeError,
        in ParcelFileDescriptor image,
        in ParcelFileDescriptor input,
        in ParcelFileDescriptor output,
        @nullable IAndeeNetworkBroker networkBroker,
        @nullable String resolverConfiguration
    );
    void stop();
}
