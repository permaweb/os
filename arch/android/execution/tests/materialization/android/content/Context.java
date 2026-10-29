package android.content;

import java.io.File;

/** Only the app-private root lookup used by AndeePaths; no device behavior. */
public final class Context {
    private final File root;
    public Context(File root) { this.root = root; }
    public File getNoBackupFilesDir() { return root; }
}
