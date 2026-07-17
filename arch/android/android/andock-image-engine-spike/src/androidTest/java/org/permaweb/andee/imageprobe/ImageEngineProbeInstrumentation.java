package org.permaweb.andee.imageprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.os.RemoteException;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class ImageEngineProbeInstrumentation extends Instrumentation {
    private static final long BIND_TIMEOUT_SECONDS = 15;
    private static final AtomicInteger INSTANCE = new AtomicInteger();

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        new Thread(this::execute, "andock-image-engine-probe").start();
    }

    private void execute() {
        Bundle output = new Bundle();
        int resultCode = Activity.RESULT_CANCELED;
        StringBuilder report = new StringBuilder();
        try {
            Context context = getTargetContext();
            File root = new File(context.getNoBackupFilesDir(), "andock-image-engine-probe");
            deleteRecursively(root);
            requireDirectory(root);

            File image = new File(root, "member.ext4");
            Connection first = bind(context);
            int firstUid = first.probe.isolatedUid();
            int firstPid = first.probe.isolatedPid();
            report.append("owner-uid=").append(Process.myUid()).append('\n');
            report.append("first-isolated-uid=").append(firstUid).append('\n');
            report.append("first-isolated-pid=").append(firstPid).append('\n');
            report.append("isolated-uid-boundary=")
                .append(firstUid != Process.myUid() ? "ok" : "failed")
                .append('\n');

            String initialized;
            try (ParcelFileDescriptor descriptor = image(image, true)) {
                initialized = first.probe.initialize(descriptor);
            }
            report.append("INITIALIZE\n").append(initialized);
            requireSuccess("initialize", initialized);
            require(image.isFile() && image.length() == 64L * 1024L * 1024L,
                "owner did not retain the opaque 64 MiB member image");

            CountDownLatch death = new CountDownLatch(1);
            first.binder.linkToDeath(death::countDown, 0);
            try (ParcelFileDescriptor descriptor = image(image, false)) {
                try {
                    first.probe.crashAfterMutation(descriptor);
                    throw new IllegalStateException("crash call unexpectedly returned");
                } catch (RemoteException expected) {
                    report.append("crash-call-binder-death=ok\n");
                }
            }
            require(
                death.await(BIND_TIMEOUT_SECONDS, TimeUnit.SECONDS),
                "isolated image parser did not die at crash point"
            );
            context.unbindService(first.connection);

            Connection second = bind(context);
            int secondPid = second.probe.isolatedPid();
            report.append("second-isolated-pid=").append(secondPid).append('\n');
            report.append("isolated-service-restarted=")
                .append(secondPid != firstPid ? "ok" : "failed")
                .append('\n');
            String verified;
            try (ParcelFileDescriptor descriptor = image(image, false)) {
                verified = second.probe.verify(descriptor);
            }
            report.append("VERIFY_AFTER_CRASH\n").append(verified);
            requireSuccess("verify after crash", verified);

            File copy = new File(root, "member-copy.ext4");
            String copied;
            try (
                ParcelFileDescriptor source = image(image, false);
                ParcelFileDescriptor destination = image(copy, true)
            ) {
                copied = NativeProbe.sparseCopy(source.getFd(), destination.getFd());
            }
            report.append("SPARSE_COPY\n").append(copied);
            requireSuccess("sparse copy", copied);
            String copyVerified;
            try (ParcelFileDescriptor descriptor = image(copy, false)) {
                copyVerified = second.probe.verify(descriptor);
            }
            report.append("VERIFY_SPARSE_COPY\n").append(copyVerified);
            requireSuccess("verify sparse copy", copyVerified);

            for (int kind = 0; kind < 4; ++kind) {
                File malformed = new File(root, "malformed-" + kind + ".ext4");
                String rejected;
                try (ParcelFileDescriptor descriptor = image(malformed, true)) {
                    rejected = second.probe.rejectMalformed(descriptor, kind);
                }
                report.append("MALFORMED_").append(kind).append('\n').append(rejected);
                requireSuccess("malformed image " + kind, rejected);
                require(
                    rejected.contains("malformed-rejected=ok\n"),
                    "malformed image " + kind + " was accepted"
                );
            }
            context.unbindService(second.connection);

            report.append("regular-file-image-capability=ok\n");
            File evidence = new File(context.getFilesDir(), "andock-image-engine-report.txt");
            write(evidence, report.toString());
            output.putString("report-path", evidence.getAbsolutePath());
            output.putString("stream", "\nANDOCK_IMAGE_ENGINE_PROBE\n" + report);
            resultCode = Activity.RESULT_OK;
        } catch (Throwable error) {
            report.append("probe-error=").append(error).append('\n');
            output.putString("error", error.toString());
            output.putString("stream", "\nANDOCK_IMAGE_ENGINE_PROBE_ERROR\n" + report);
        }
        finish(resultCode, output);
    }

    private static ParcelFileDescriptor image(File file, boolean truncate) throws Exception {
        File parent = file.getParentFile();
        if (parent != null) {
            requireDirectory(parent);
        }
        int mode = ParcelFileDescriptor.MODE_CREATE | ParcelFileDescriptor.MODE_READ_WRITE;
        if (truncate) {
            mode |= ParcelFileDescriptor.MODE_TRUNCATE;
        }
        return ParcelFileDescriptor.open(file, mode);
    }

    private static Connection bind(Context context) throws Exception {
        CountDownLatch connected = new CountDownLatch(1);
        Connection result = new Connection(connected);
        Intent intent = new Intent(context, ImageEngineProbeService.class);
        if (!context.bindIsolatedService(
                intent,
                Context.BIND_AUTO_CREATE,
                "image-probe-" + INSTANCE.incrementAndGet(),
                context.getMainExecutor(),
                result.connection)) {
            throw new IllegalStateException("bindIsolatedService returned false");
        }
        if (!connected.await(BIND_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            context.unbindService(result.connection);
            throw new IllegalStateException("isolated service bind timed out");
        }
        return result;
    }

    private static void requireSuccess(String stage, String value) {
        require(value != null && value.contains("result=ok\n"), stage + " failed:\n" + value);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalStateException(message);
        }
    }

    private static void requireDirectory(File directory) {
        if (!directory.mkdirs() && !directory.isDirectory()) {
            throw new IllegalStateException("failed to create " + directory);
        }
    }

    private static void write(File file, String value) throws Exception {
        try (FileOutputStream output = new FileOutputStream(file, false)) {
            output.write(value.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }

    private static void deleteRecursively(File file) {
        if (!file.exists()) {
            return;
        }
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        if (!file.delete()) {
            throw new IllegalStateException("failed to delete " + file);
        }
    }

    private static final class Connection {
        final ServiceConnection connection;
        volatile IImageEngineProbe probe;
        volatile IBinder binder;

        Connection(CountDownLatch connected) {
            connection = new ServiceConnection() {
                @Override
                public void onServiceConnected(ComponentName name, IBinder service) {
                    binder = service;
                    probe = IImageEngineProbe.Stub.asInterface(service);
                    connected.countDown();
                }

                @Override
                public void onServiceDisconnected(ComponentName name) {
                    // Binder death is observed explicitly for the crash/reopen test.
                }
            };
        }
    }
}
