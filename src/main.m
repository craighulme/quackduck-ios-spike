#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <jni.h>
#include <unistd.h>

typedef jint JLI_Launch(int, const char **, int, const char **, int,
                       const char **, const char *, const char *, const char *,
                       const char *, jboolean, jboolean, jboolean, jint);
typedef jint QDGetCreatedJavaVMs(JavaVM **, jsize, jsize *);

static JLI_Launch *gLaunch;
static JavaVM *gVM;
static jclass gInputClass;
static jmethodID gReceiveInput;

enum {
    QDInputChar = 1000,
    QDInputCursor = 1003,
    QDInputKey = 1005,
    QDInputMouseButton = 1006,
    QDButton1DownMask = 1024,
};

static JNIEnv *QDEnv(void) {
    if (!gVM) return NULL;
    JNIEnv *env = NULL;
    jint result = (*gVM)->GetEnv(gVM, (void **)&env, JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
        result = (*gVM)->AttachCurrentThread(gVM, &env, NULL);
    }
    return result == JNI_OK ? env : NULL;
}

static void QDSendInput(int type, int a, int b, int c, int d) {
    JNIEnv *env = QDEnv();
    if (!env) return;
    if (!gInputClass) {
        jclass local = (*env)->FindClass(env,
            "com/github/caciocavallosilano/cacio/ctc/CTCAndroidInput");
        if (!local) {
            (*env)->ExceptionClear(env);
            return;
        }
        gInputClass = (*env)->NewGlobalRef(env, local);
        gReceiveInput = (*env)->GetStaticMethodID(env, gInputClass,
            "receiveData", "(IIIII)V");
    }
    if (gReceiveInput) {
        (*env)->CallStaticVoidMethod(env, gInputClass, gReceiveInput,
                                    type, a, b, c, d);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
}

static void QDSendKey(int key) {
    QDSendInput(QDInputKey, ' ', key, 1, 0);
    QDSendInput(QDInputKey, ' ', key, 0, 0);
}

@interface QDSurfaceView : UIView
@property(nonatomic) int pixelWidth;
@property(nonatomic) int pixelHeight;
@property(nonatomic, copy) void (^firstFrame)(void);
- (void)startDisplayLoop;
@end

@implementation QDSurfaceView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.layer.magnificationFilter = kCAFilterLinear;
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (void)sendCursor:(UITouch *)touch {
    CGPoint point = [touch locationInView:self];
    int x = (int)round(point.x * self.pixelWidth / MAX(self.bounds.size.width, 1));
    int y = (int)round(point.y * self.pixelHeight / MAX(self.bounds.size.height, 1));
    QDSendInput(QDInputCursor, x, y, 0, 0);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendCursor:touches.anyObject];
    QDSendInput(QDInputMouseButton, QDButton1DownMask, 1, 0, 0);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendCursor:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendCursor:touches.anyObject];
    QDSendInput(QDInputMouseButton, QDButton1DownMask, 0, 0, 0);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    QDSendInput(QDInputMouseButton, QDButton1DownMask, 0, 0, 0);
}

- (void)startDisplayLoop {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        JNIEnv *env = NULL;
        while (!(env = QDEnv())) usleep(100000);

        jclass screen = (*env)->FindClass(env,
            "com/github/caciocavallosilano/cacio/ctc/CTCScreen");
        if (!screen) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            return;
        }
        jmethodID getRGB = (*env)->GetStaticMethodID(env, screen,
            "getCurrentScreenRGB", "()[I");
        BOOL sentFirstFrame = NO;

        for (;;) {
            jintArray array = (jintArray)(*env)->CallStaticObjectMethod(env, screen, getRGB);
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionDescribe(env);
                (*env)->ExceptionClear(env);
                usleep(250000);
                continue;
            }
            if (!array) {
                usleep(100000);
                continue;
            }

            jsize count = (*env)->GetArrayLength(env, array);
            size_t expected = (size_t)self.pixelWidth * self.pixelHeight;
            if ((size_t)count >= expected) {
                NSMutableData *pixels = [NSMutableData dataWithLength:expected * 4];
                (*env)->GetIntArrayRegion(env, array, 0, (jsize)expected, pixels.mutableBytes);
                dispatch_async(dispatch_get_main_queue(), ^{
                    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
                        (__bridge CFDataRef)pixels);
                    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
                    CGImageRef image = CGImageCreate(
                        self.pixelWidth, self.pixelHeight, 8, 32,
                        self.pixelWidth * 4, colors,
                        kCGImageAlphaFirst | kCGBitmapByteOrder32Little,
                        provider, NULL, false, kCGRenderingIntentDefault);
                    self.layer.contents = (__bridge id)image;
                    self.layer.contentsGravity = kCAGravityResizeAspect;
                    CGImageRelease(image);
                    CGColorSpaceRelease(colors);
                    CGDataProviderRelease(provider);
                });
                if (!sentFirstFrame) {
                    sentFirstFrame = YES;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.firstFrame) self.firstFrame();
                    });
                }
            }
            (*env)->DeleteLocalRef(env, array);
            usleep(50000);
        }
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate, UITextFieldDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) QDSurfaceView *surface;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UITextField *keyboard;
@end

static NSString *RunJava(int width, int height) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *javaHome = [bundle stringByAppendingPathComponent:@"jre"];
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *sentinel = [documents stringByAppendingPathComponent:@"java-ok.txt"];

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    setenv("HOME", documents.UTF8String, 1);
    setenv("QD_SENTINEL", sentinel.UTF8String, 1);
    setenv("LD_LIBRARY_PATH", [[javaHome stringByAppendingPathComponent:@"lib"] UTF8String], 1);

    NSString *jliPath = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
    void *jli = dlopen(jliPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!jli) return [NSString stringWithFormat:@"dlopen failed: %s", dlerror()];
    gLaunch = (JLI_Launch *)dlsym(jli, "JLI_Launch");
    if (!gLaunch) return @"JLI_Launch was not found";

    NSString *java = [javaHome stringByAppendingPathComponent:@"bin/java"];
    NSString *screen = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height];
    NSString *cacio = [bundle stringByAppendingPathComponent:@"libs_caciocavallo17"];
    NSArray<NSString *> *cacioFiles = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:cacio error:nil];
    NSMutableString *boot = [NSMutableString stringWithString:@"-Xbootclasspath/a:"];
    for (NSString *file in cacioFiles) {
        if ([file hasSuffix:@".jar"]) [boot appendFormat:@"%@/%@:", cacio, file];
    }
    NSString *classpath = [NSString stringWithFormat:@"%@/classes:%@/libs/*", bundle, bundle];
    NSString *libraryPath = [@"-Djava.library.path=" stringByAppendingString:
        [javaHome stringByAppendingPathComponent:@"lib"]];
    NSString *fontPath = [@"-Dsun.java2d.fontpath=" stringByAppendingString:
        [javaHome stringByAppendingPathComponent:@"lib/fonts"]];
    NSString *userHome = [@"-Duser.home=" stringByAppendingString:documents];

    const char *args[] = {
        java.UTF8String, "-Xms128m", "-Xmx768m",
        "-XX:+UnlockExperimentalVMOptions", "-XX:+DisablePrimordialThreadGuardPages",
        "-XX:-UseCompressedClassPointers", "-Djava.awt.headless=false",
        "-Dos.name=iOS",
        "-Dcacio.font.fontmanager=sun.awt.X11FontManager",
        "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler", screen.UTF8String,
        "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel",
        "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit",
        "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment",
        "--add-exports=java.desktop/java.awt=ALL-UNNAMED",
        "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
        "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
        "--add-exports=java.desktop/sun.font=ALL-UNNAMED",
        "--add-exports=java.base/sun.security.action=ALL-UNNAMED",
        "--add-opens=java.base/java.net=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
        "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.font=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
        "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
        boot.UTF8String, libraryPath.UTF8String, fontPath.UTF8String, userHome.UTF8String,
        "-cp", classpath.UTF8String, "dev.quackduck.Launcher"
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSString *jvmPath = [javaHome stringByAppendingPathComponent:@"lib/server/libjvm.dylib"];
        QDGetCreatedJavaVMs *getVMs = NULL;
        while (!getVMs) {
            void *jvm = dlopen(jvmPath.UTF8String, RTLD_NOW | RTLD_NOLOAD);
            if (jvm) getVMs = (QDGetCreatedJavaVMs *)dlsym(jvm, "JNI_GetCreatedJavaVMs");
            if (!getVMs) usleep(100000);
        }
        jsize count = 0;
        while (count == 0) {
            getVMs(&gVM, 1, &count);
            if (count == 0) usleep(100000);
        }
    });

    NSLog(@"QD_IOS: launching RuneLite at %dx%d", width, height);
    int result = gLaunch((int)(sizeof(args) / sizeof(args[0])), args,
                         0, NULL, 0, NULL, "17", "17", "java",
                         "openjdk", 0, 1, 0, 1);
    return [NSString stringWithFormat:@"RuneLite exited with %d", result];
}

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;

    self.surface = [[QDSurfaceView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.surface.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:self.surface];

    self.status = [[UILabel alloc] initWithFrame:controller.view.bounds];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    self.status.textColor = UIColor.whiteColor;
    self.status.backgroundColor = UIColor.blackColor;
    self.status.text = @"Starting RuneLite…";
    [controller.view addSubview:self.status];

    UIButton *keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    keyboardButton.frame = CGRectMake(12, 12, 48, 40);
    keyboardButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin |
                                      UIViewAutoresizingFlexibleBottomMargin;
    keyboardButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    keyboardButton.layer.cornerRadius = 8;
    [keyboardButton setTitle:@"⌨" forState:UIControlStateNormal];
    keyboardButton.titleLabel.font = [UIFont systemFontOfSize:24];
    [keyboardButton addTarget:self action:@selector(toggleKeyboard)
             forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:keyboardButton];

    self.keyboard = [[UITextField alloc] initWithFrame:CGRectMake(-2, -2, 1, 1)];
    self.keyboard.delegate = self;
    self.keyboard.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyboard.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.keyboard.returnKeyType = UIReturnKeyDone;
    [controller.view addSubview:self.keyboard];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    CGRect bounds = controller.view.bounds;
    self.surface.pixelWidth = (int)floor(MAX(bounds.size.width, bounds.size.height));
    self.surface.pixelHeight = (int)floor(MIN(bounds.size.width, bounds.size.height));
    if (self.surface.pixelWidth % 2) self.surface.pixelWidth--;
    if (self.surface.pixelHeight % 2) self.surface.pixelHeight--;
    __weak AppDelegate *weakSelf = self;
    self.surface.firstFrame = ^{ weakSelf.status.hidden = YES; };
    [self.surface startDisplayLoop];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = RunJava(self.surface.pixelWidth, self.surface.pixelHeight);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.hidden = NO;
            self.status.text = result;
        });
    });
    return YES;
}

- (void)toggleKeyboard {
    if (self.keyboard.isFirstResponder) [self.keyboard resignFirstResponder];
    else [self.keyboard becomeFirstResponder];
}

- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)string {
    if (range.length > 0 && string.length == 0) QDSendKey(8);
    for (NSUInteger i = 0; i < string.length; i++) {
        QDSendInput(QDInputChar, [string characterAtIndex:i], 0, 0, 0);
    }
    textField.text = @"";
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    QDSendKey(10);
    [textField resignFirstResponder];
    return NO;
}
@end

int main(int argc, char *argv[]) {
    if (gLaunch) {
        NSLog(@"QD_IOS: handling JLI native-main re-entry");
        return gLaunch(argc, (const char **)argv, 0, NULL, 0, NULL,
                       "17", "17", "java", "openjdk", 0, 1, 0, 1);
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
