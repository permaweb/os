package android.system;

import java.io.FileDescriptor;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/** Real host rename; directory fsync is outside this coordinator test's scope. */
public final class Os {
    public static void rename(String from, String to) throws IOException {
        Files.move(Path.of(from), Path.of(to), StandardCopyOption.REPLACE_EXISTING);
    }
    public static FileDescriptor open(String path, int flags, int mode) { return new FileDescriptor(); }
    public static void fsync(FileDescriptor descriptor) {}
    public static void close(FileDescriptor descriptor) {}
}
