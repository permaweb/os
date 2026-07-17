package org.permaweb.andee;

import org.permaweb.andee.AndeeSocketResult;

/** Main-UID capability exposed only to one isolated execution command. */
interface IAndeeNetworkBroker {
    AndeeSocketResult createSocket(int family, int type, int protocol);
    int authorizeDestination(
        int family,
        int transport,
        int port,
        int scopeId,
        in byte[] address
    );
}
