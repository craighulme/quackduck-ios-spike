# QuackDuck iOS JVM spike

This deliberately tiny experiment answers one question: can an ARM64 iOS
Simulator app boot the iOS OpenJDK 17 runtime used by Amethyst/Pojav?

GitHub Actions builds and launches `QuackDuckJVM.app`. The Java program writes
`JAVA_OK` from inside the simulator; the job fails if that file never appears.
The artifact contains the `.app` zip, screenshot, app log, and Java result.

The runtime is downloaded at build time from the current
[Amethyst iOS](https://github.com/AngelAuraMC/Amethyst-iOS) OpenJDK distribution
and is not stored in this repository.

