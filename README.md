# QuackDuck RuneLite iOS port

This is the first runnable iOS host for RuneLite. It embeds the iOS OpenJDK 17
runtime and Caciocavallo AWT backend used by Amethyst, then boots RuneLite's
normal JVM client inside an ARM64 iOS Simulator app.

The native host displays AWT's framebuffer and maps iOS taps, keyboard input,
modifier keys, OAuth links, and sideloaded plugin jars back to desktop RuneLite.
GitHub Actions builds and launches the app; the job
fails if the JVM cannot resolve RuneLite's main class. Its artifact contains the
Appetize-ready `.app` zip, screenshot, app log, and boot result.

The runtime is downloaded at build time from the current
[Amethyst iOS](https://github.com/AngelAuraMC/Amethyst-iOS) OpenJDK distribution
and is not stored in this repository. The default RuneLite client is fetched
from RuneLite's official Maven repository; set `RUNELITE_JAR_URL` to package a
compatible shaded client instead.
