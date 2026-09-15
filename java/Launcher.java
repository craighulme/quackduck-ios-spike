package dev.quackduck;

import java.awt.Font;
import java.awt.GraphicsEnvironment;
import java.io.PrintWriter;
import java.io.PrintStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

public final class Launcher {
    public static void main(String[] args) throws Throwable {
        Path status = Path.of(System.getenv("QD_SENTINEL"));
        Path log = status.resolveSibling("runelite.log");
        PrintStream output = new PrintStream(Files.newOutputStream(log), true);
        System.setOut(output);
        System.setErr(output);
        Files.writeString(status, "JVM_OK " + System.getProperty("java.version") + "\nRUNITELITE_LOADING\n");

        try {
            Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCPreloadClassLoader");
            Path font = Path.of(System.getProperty("java.home"), "lib", "fonts", "NotoSans.ttf");
            GraphicsEnvironment.getLocalGraphicsEnvironment()
                .registerFont(Font.createFont(Font.TRUETYPE_FONT, font.toFile()));
            configureMobileWindow();
            Files.writeString(status, Files.readString(status) + "AWT_BRIDGE_OK\n");
            Class<?> runelite = Class.forName("net.runelite.client.RuneLite");
            Files.writeString(status, Files.readString(status) + "RUNITELITE_CLASS_OK\n");
            runelite.getMethod("main", String[].class).invoke(null, (Object) args);
        } catch (Throwable failure) {
            if (failure instanceof InvocationTargetException && failure.getCause() != null) {
                failure = failure.getCause();
            }
            try (PrintWriter out = new PrintWriter(Files.newBufferedWriter(status))) {
                out.println("RUNITELITE_FAILED");
                failure.printStackTrace(out);
            }
            failure.printStackTrace();
            throw failure;
        }
    }

    private static void configureMobileWindow() throws Exception {
        var screen = GraphicsEnvironment.getLocalGraphicsEnvironment()
            .getMaximumWindowBounds();
        Path file = Path.of(System.getProperty("user.home"), ".runelite", "settings.properties");
        Files.createDirectories(file.getParent());
        Properties settings = new Properties();
        if (Files.isRegularFile(file)) {
            try (InputStream in = Files.newInputStream(file)) {
                settings.load(in);
            }
        }
        settings.setProperty("runelite.automaticResizeType", "KEEP_WINDOW_SIZE");
        settings.setProperty("runelite.gameSize",
            (screen.width - 40) + "x" + (screen.height - 40));
        settings.setProperty("runelite.clientBounds",
            "0:0:" + screen.width + ":" + screen.height + ":c");
        try (OutputStream out = Files.newOutputStream(file)) {
            settings.store(out, "QuackDuck iOS window defaults");
        }
    }
}
