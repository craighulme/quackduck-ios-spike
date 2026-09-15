import java.nio.file.Files;
import java.nio.file.Path;

public final class Hello {
    public static void main(String[] args) throws Exception {
        String result = "JAVA_OK " + System.getProperty("java.version") + " "
                + System.getProperty("os.arch") + System.lineSeparator();
        Files.writeString(Path.of(System.getenv("QD_SENTINEL")), result);
        System.out.print(result);
        Thread.sleep(300_000);
    }
}

