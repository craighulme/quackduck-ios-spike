#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
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
static jclass gLauncherClass;
static jmethodID gRepaintWindows;

static void QDDisableMicrophoneRequest(void) {
    Method method = class_getInstanceMethod(AVAudioSession.class,
        @selector(requestRecordPermission:));
    if (method) method_setImplementation(method, imp_implementationWithBlock(
        ^(__unused id session, void (^reply)(BOOL)) { if (reply) reply(NO); }));
}

enum {
    QDInputChar = 1000,
    QDInputCursor = 1003,
    QDInputKey = 1005,
    QDInputMouseButton = 1006,
    QDButton1DownMask = 1024,
    QDButton3DownMask = 4096,
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

static void QDSetKey(int key, BOOL pressed) {
    QDSendInput(QDInputKey, ' ', key, pressed ? 1 : 0, 0);
}

static void QDRepaint(void) {
    JNIEnv *env = QDEnv();
    if (!env) return;
    if (!gLauncherClass) {
        jclass local = (*env)->FindClass(env, "dev/quackduck/Launcher");
        if (!local) {
            (*env)->ExceptionClear(env);
            return;
        }
        gLauncherClass = (*env)->NewGlobalRef(env, local);
        gRepaintWindows = (*env)->GetStaticMethodID(env, gLauncherClass,
            "repaintAllWindows", "()V");
    }
    if (gRepaintWindows) (*env)->CallStaticVoidMethod(env, gLauncherClass,
                                                       gRepaintWindows);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

@interface QDSurfaceView : UIView
@property(nonatomic) int pixelWidth;
@property(nonatomic) int pixelHeight;
@property(nonatomic, copy) void (^firstFrame)(void);
@property(nonatomic) NSInteger hoveredMenuRow;
- (void)startDisplayLoop;
@end

@implementation QDSurfaceView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.layer.magnificationFilter = kCAFilterLinear;
        self.multipleTouchEnabled = NO;

        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleHold:)];
        hold.minimumPressDuration = 0.4;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleTap:)];
        [tap requireGestureRecognizerToFail:hold];
        [self addGestureRecognizer:hold];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)sendCursorAt:(CGPoint)point {
    int x = (int)round(point.x * self.pixelWidth / MAX(self.bounds.size.width, 1));
    int y = (int)round(point.y * self.pixelHeight / MAX(self.bounds.size.height, 1));
    QDSendInput(QDInputCursor, x, y, 0, 0);
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    [self sendCursorAt:[gesture locationInView:self]];
    QDSendInput(QDInputMouseButton, QDButton1DownMask, 1, 0, 0);
    QDSendInput(QDInputMouseButton, QDButton1DownMask, 0, 0, 0);
    QDRepaint();
}

- (void)handleHold:(UILongPressGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self];
    [self sendCursorAt:point];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.hoveredMenuRow = -1;
        QDSendInput(QDInputMouseButton, QDButton3DownMask, 1, 0, 0);
        QDSendInput(QDInputMouseButton, QDButton3DownMask, 0, 0, 0);
        [[[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        NSInteger row = (NSInteger)floor(point.y * self.pixelHeight /
                                         MAX(self.bounds.size.height, 1) / 15.0);
        if (row != self.hoveredMenuRow) {
            self.hoveredMenuRow = row;
            [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        }
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        QDSendInput(QDInputMouseButton, QDButton1DownMask, 1, 0, 0);
        QDSendInput(QDInputMouseButton, QDButton1DownMask, 0, 0, 0);
        QDRepaint();
        [[[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
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
        jfieldID instanceID = (*env)->GetStaticFieldID(env, screen, "instance",
            "Lcom/github/caciocavallosilano/cacio/ctc/CTCScreen;");
        while (!(*env)->GetStaticObjectField(env, screen, instanceID)) usleep(100000);
        BOOL sentFirstFrame = NO;

        for (;;) {
            jintArray array = (jintArray)(*env)->CallStaticObjectMethod(env, screen, getRGB);
            if ((*env)->ExceptionCheck(env)) {
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

@interface AppDelegate : UIResponder <UIApplicationDelegate, UITextFieldDelegate,
                                      UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) QDSurfaceView *surface;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UITextField *keyboard;
@property(nonatomic, strong) UIButton *shiftButton;
@property(nonatomic, strong) UIButton *controlButton;
@property(nonatomic, strong) UIButton *altButton;
@property(nonatomic) BOOL shiftDown;
@property(nonatomic) BOOL controlDown;
@property(nonatomic) BOOL altDown;
@property(nonatomic, strong) dispatch_source_t urlTimer;
@end

static NSString *RunJava(int width, int height) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *javaHome = [bundle stringByAppendingPathComponent:@"jre"];
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *sentinel = [documents stringByAppendingPathComponent:@"java-ok.txt"];
    NSString *urlRequest = [documents stringByAppendingPathComponent:@"open-url.txt"];

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
    NSString *urlProperty = [@"-Dqd.url.request=" stringByAppendingString:urlRequest];

    const char *args[] = {
        java.UTF8String, "-Xms128m", "-Xmx768m", "-ea",
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
        "--add-modules=jdk.httpserver",
        boot.UTF8String, libraryPath.UTF8String, fontPath.UTF8String,
        userHome.UTF8String, urlProperty.UTF8String,
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
    QDDisableMicrophoneRequest();
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

    UIStackView *controls = [[UIStackView alloc] init];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.spacing = 3;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    controls.layer.cornerRadius = 8;
    controls.layoutMargins = UIEdgeInsetsMake(3, 4, 3, 4);
    controls.layoutMarginsRelativeArrangement = YES;
    NSArray *titles = @[@"⌨", @"⇧", @"Ctrl", @"Alt", @"Esc", @"📦"];
    NSArray *actions = @[@"toggleKeyboard", @"toggleShift:", @"toggleControl:",
                         @"toggleAlt:", @"sendEscape", @"importPlugin"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:titles[i] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        button.tintColor = UIColor.whiteColor;
        button.accessibilityLabel = titles[i];
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:38].active = YES;
        [button addTarget:self action:NSSelectorFromString(actions[i])
                 forControlEvents:UIControlEventTouchUpInside];
        [controls addArrangedSubview:button];
        if (i == 1) self.shiftButton = button;
        if (i == 2) self.controlButton = button;
        if (i == 3) self.altButton = button;
    }
    [controller.view addSubview:controls];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [controls.topAnchor constraintEqualToAnchor:safe.topAnchor constant:3],
        [controls.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [controls.heightAnchor constraintEqualToConstant:36]
    ]];

    self.keyboard = [[UITextField alloc] initWithFrame:CGRectMake(-2, -2, 1, 1)];
    self.keyboard.delegate = self;
    self.keyboard.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyboard.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.keyboard.returnKeyType = UIReturnKeyDone;
    [controller.view addSubview:self.keyboard];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    [self startURLBridge];

    CGRect bounds = controller.view.bounds;
    self.surface.pixelHeight = 540;
    self.surface.pixelWidth = (int)round(self.surface.pixelHeight *
        MAX(bounds.size.width, bounds.size.height) /
        MAX(MIN(bounds.size.width, bounds.size.height), 1));
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

- (void)setModifierButton:(UIButton *)button active:(BOOL)active {
    button.backgroundColor = active ? [UIColor systemBlueColor] : UIColor.clearColor;
    button.layer.cornerRadius = 5;
}

- (void)toggleShift:(UIButton *)sender {
    self.shiftDown = !self.shiftDown;
    QDSetKey(16, self.shiftDown);
    [self setModifierButton:sender active:self.shiftDown];
}

- (void)toggleControl:(UIButton *)sender {
    self.controlDown = !self.controlDown;
    QDSetKey(17, self.controlDown);
    [self setModifierButton:sender active:self.controlDown];
}

- (void)toggleAlt:(UIButton *)sender {
    self.altDown = !self.altDown;
    QDSetKey(18, self.altDown);
    [self setModifierButton:sender active:self.altDown];
}

- (void)sendEscape { QDSendKey(27); }

- (void)importPlugin {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self.window.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [documents stringByAppendingPathComponent:
        @".runelite/sideloaded-plugins"];
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:directory withIntermediateDirectories:YES
                      attributes:nil error:nil];
    NSUInteger imported = 0;
    for (NSURL *url in urls) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
        NSString *name = url.lastPathComponent;
        NSString *target = [directory stringByAppendingPathComponent:name];
        for (NSUInteger suffix = 2; [files fileExistsAtPath:target]; suffix++) {
            NSString *base = name.stringByDeletingPathExtension;
            target = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%lu.jar", base, (unsigned long)suffix]];
        }
        if ([files copyItemAtPath:url.path toPath:target error:nil]) imported++;
    }
    NSString *message = imported ? @"Plugin imported. Restart QuackDuck to load it."
                                 : @"Choose one or more .jar plugin files.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Sideload"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)startURLBridge {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *request = [documents stringByAppendingPathComponent:@"open-url.txt"];
    self.urlTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
    dispatch_source_set_timer(self.urlTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC / 4, NSEC_PER_SEC / 20);
    dispatch_source_set_event_handler(self.urlTimer, ^{
        NSString *value = [NSString stringWithContentsOfFile:request
            encoding:NSUTF8StringEncoding error:nil];
        if (!value.length) return;
        [NSFileManager.defaultManager removeItemAtPath:request error:nil];
        NSURL *url = [NSURL URLWithString:value];
        if (url && ([url.scheme isEqualToString:@"https"] ||
                    [url.scheme isEqualToString:@"http"])) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
    });
    dispatch_resume(self.urlTimer);
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
