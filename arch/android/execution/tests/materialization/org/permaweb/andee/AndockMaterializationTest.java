package org.permaweb.andee;

import android.content.Context;
import android.util.Log;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/** Runs the production coordinator/expander, with host-only Android boundary stubs. */
public final class AndockMaterializationTest {
    private static final String ID = "a".repeat(43);
    private static final long SIZE = 1024L * 1024 * 1024;
    private static final String FAILURE = "invalid-android-sparse-image-magic";

    public static void main(String[] args) throws Exception {
        File root = Files.createTempDirectory("andock-materialization-").toFile();
        try {
            Context context = new Context(root);
            File source = new File(AndeePaths.INSTANCE.andockImagesRoot(context), ID + ".simg");
            check(source.getParentFile().mkdirs(), "create source directory");
            byte[] valid = sparseImage();
            byte[] corrupt = valid.clone();
            corrupt[0] = 0;
            Files.write(source.toPath(), corrupt);
            File runtime = new File(root, "runtime");
            File manifest = new File(runtime, "execution/andock/andock-ubuntu-arm64.ext4.manifest.json");
            check(manifest.getParentFile().mkdirs(), "create manifest directory");
            Files.writeString(manifest.toPath(), new JSONObject()
                .put("architecture", "arm64").put("sparse-image-format", "android-sparse-v1")
                .put("sparse-image-bytes", valid.length).put("image-logical-bytes", SIZE)
                .put("image-sha256", zeroDigest()).toString());
            File config = new File(root, "config.json");
            Files.writeString(config.toPath(), new JSONObject().put("andock-default-image", ID).toString());
            try (AndeeAndockImageMaterializer materializer = new AndeeAndockImageMaterializer(context, runtime, config)) {
                check("missing".equals(materializer.health().get("state")), "initial state");
                expectFailure(materializer, source, valid.length, null);
                waitFor(materializer, "failed");
                check(Log.failures.get() == 1, "first implicit access starts exactly one attempt");
                for (int i = 0; i < 3; i++) {
                    expectFailure(materializer, source, valid.length, FAILURE);
                    Thread.sleep(30);
                    check(FAILURE.equals(materializer.health().get("error")), "health preserves cause");
                    check(Log.failures.get() == 1, "implicit access must not retry failed expansion");
                }
                try {
                    materializer.ensure(ID, new File(root, "other.simg").getPath(), valid.length);
                    throw new AssertionError("source path validation was skipped");
                } catch (ExecutionFailure expected) {
                    check("invalid-andock-image-path".equals(expected.getMessage()), "source validation unchanged");
                }
                check(Log.failures.get() == 1, "invalid source starts no worker");
                Log.entered = new CountDownLatch(1);
                Log.release = new CountDownLatch(1);
                materializer.prepare(ID, source.getPath(), valid.length);
                check(Log.entered.await(5, TimeUnit.SECONDS), "explicit retry reached worker");
                for (int i = 0; i < 3; i++) {
                    materializer.prepare(ID, source.getPath(), valid.length);
                    expectFailure(materializer, source, valid.length, null);
                }
                check(Log.failures.get() == 2, "active prepares and tools coalesce into one retry");
                Log.release.countDown();
                waitFor(materializer, "failed");
                Log.entered = null;
                Log.release = null;
                Files.write(source.toPath(), valid);
                expectFailure(materializer, source, valid.length, FAILURE);
                check(Log.failures.get() == 2, "corrected source still requires explicit retry");
                materializer.prepare(ID, source.getPath(), valid.length);
                waitFor(materializer, "ready");
                File installed = materializer.requireTemplate();
                check(installed.length() == SIZE, "verified logical image size");
                materializer.ensure(ID, source.getPath(), valid.length);
                materializer.prepare(ID, source.getPath(), valid.length);
                check("ready".equals(materializer.health().get("state")), "ready template reused");
                check(Log.failures.get() == 2, "ready reuse starts no attempt");
            }
            System.out.println("ANDOCK_MATERIALIZATION_TEST_OK: implicit failure retained; explicit retry; coalescing; source validation; verified ready reuse");
        } finally {
            if (Log.release != null) Log.release.countDown();
            try (var paths = Files.walk(root.toPath())) {
                for (var path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }

    private static void expectFailure(AndeeAndockImageMaterializer materializer, File source, int bytes, String reason) {
        try {
            materializer.ensure(ID, source.getPath(), bytes);
            throw new AssertionError("uninstalled toolkit unexpectedly ready");
        } catch (ExecutionFailure expected) {
            check(expected.getStatus() == 503, "original status retained");
            if (reason != null) check(reason.equals(expected.getMessage()), "original failure retained: " + expected.getMessage());
        }
    }
    private static void waitFor(AndeeAndockImageMaterializer materializer, String state) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (!state.equals(materializer.health().get("state"))) {
            check(System.nanoTime() < deadline, "timed out: " + materializer.health());
            Thread.sleep(10);
        }
    }
    private static byte[] sparseImage() {
        return ByteBuffer.allocate(40).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(0xed26ff3a).putShort((short) 1).putShort((short) 0)
            .putShort((short) 28).putShort((short) 12).putInt(4096)
            .putInt((int) (SIZE / 4096)).putInt(1).putInt(0)
            .putShort((short) 0xcac3).putShort((short) 0).putInt((int) (SIZE / 4096)).putInt(12).array();
    }
    private static String zeroDigest() throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] block = new byte[1024 * 1024];
        for (long bytes = 0; bytes < SIZE; bytes += block.length) digest.update(block);
        return HexFormat.of().formatHex(digest.digest());
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
