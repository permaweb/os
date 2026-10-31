package android.util;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Observes attempts and holds a failing worker to test concurrent coalescing. */
public final class Log {
    public static final AtomicInteger failures = new AtomicInteger();
    public static volatile CountDownLatch entered;
    public static volatile CountDownLatch release;
    public static int e(String tag, String message, Throwable failure) {
        failures.incrementAndGet();
        CountDownLatch waiting = entered;
        CountDownLatch resume = release;
        if (waiting != null && resume != null) {
            waiting.countDown();
            try {
                if (!resume.await(5, TimeUnit.SECONDS)) throw new AssertionError("test worker not released");
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
            }
        }
        return 0;
    }
    public static int i(String tag, String message) { return 0; }
}
