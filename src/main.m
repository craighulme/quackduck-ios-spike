#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <unistd.h>

typedef int jint;
typedef unsigned char jboolean;
typedef jint JLI_Launch(int, const char **, int, const char **, int,
                       const char **, const char *, const char *, const char *,
                       const char *, jboolean, jboolean, jboolean, jint);
static JLI_Launch *gLaunch;

static NSString *RunJava(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *javaHome = [bundle stringByAppendingPathComponent:@"jre"];
    NSString *jliPath = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
    NSString *classes = [bundle stringByAppendingPathComponent:@"classes"];
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *sentinel = [documents stringByAppendingPathComponent:@"java-ok.txt"];

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    setenv("QD_SENTINEL", sentinel.UTF8String, 1);

    void *jli = dlopen(jliPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!jli) return [NSString stringWithFormat:@"dlopen failed: %s", dlerror()];

    gLaunch = (JLI_Launch *)dlsym(jli, "JLI_Launch");
    if (!gLaunch) return @"JLI_Launch was not found";

    NSString *java = [javaHome stringByAppendingPathComponent:@"bin/java"];
    NSString *classpath = [@"-Djava.class.path=" stringByAppendingString:classes];
    const char *args[] = {
        java.UTF8String,
        "-Xms32m", "-Xmx128m",
        "-XX:+UnlockExperimentalVMOptions",
        "-XX:+DisablePrimordialThreadGuardPages",
        "-XX:-UseCompressedClassPointers",
        classpath.UTF8String,
        "Hello"
    };
    NSLog(@"QD_JVM: calling JLI_Launch");
    int result = gLaunch(8, args, 0, NULL, 0, NULL, "17", "17", "java",
                         "openjdk", 0, 1, 0, 1);
    return [NSString stringWithFormat:@"JVM exited with %d", result];
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *status;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;

    self.status = [[UILabel alloc] initWithFrame:controller.view.bounds];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    self.status.text = @"Starting embedded Java 17…";
    [controller.view addSubview:self.status];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSString *result = RunJava();
      dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = result; });
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSString *sentinel = [NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"java-ok.txt"];
      for (int i = 0; i < 45; i++) {
        NSString *result = [NSString stringWithContentsOfFile:sentinel
            encoding:NSUTF8StringEncoding error:nil];
        if (result) {
          dispatch_async(dispatch_get_main_queue(), ^{
            self.status.text = [@"Embedded JVM running\n\n" stringByAppendingString:result];
          });
          return;
        }
        sleep(1);
      }
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    if (gLaunch) {
        NSLog(@"QD_JVM: handling JLI native-main re-entry");
        return gLaunch(argc, (const char **)argv, 0, NULL, 0, NULL,
                       "17", "17", "java", "openjdk", 0, 1, 0, 1);
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
