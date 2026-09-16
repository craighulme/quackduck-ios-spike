package net.runelite.client.util;

import java.nio.file.Files;
import java.nio.file.Path;

/** Routes RuneLite's existing OAuth and help links through the native iOS host. */
public final class LinkBrowser {
    private LinkBrowser() {}

    public static void browse(String url) {
        if (url == null || !(url.startsWith("https://") || url.startsWith("http://"))) {
            throw new IllegalArgumentException("Unsupported URL");
        }
        try {
            Files.writeString(Path.of(System.getProperty("qd.url.request")), url);
        } catch (Exception failure) {
            throw new RuntimeException("Could not open browser", failure);
        }
    }

    public static void open(String path) {
        // iOS has no general folder window; the native package button exposes imports.
    }
}
