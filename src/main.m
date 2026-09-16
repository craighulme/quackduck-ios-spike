#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
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

static NSString *const QDAuthURL = @"https://quackduck.dev/api/mobile/device";
static NSString *const QDAccountURL = @"https://quackduck.dev/mobile";
static NSString *const QDLatestPlistURL = @"https://raw.githubusercontent.com/craighulme/quackduck-ios-spike/main/Info.plist";
static NSString *const QDServerPublicKey = @"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEiJ6JX7xxSxX12gR5E8bv+jVIl0VOy3b4hez05a0KkNwQjUJDMT2PpK6UbiR3ZV1WvP/PsB5/SCmtWqPYNx0U3Q==";
static NSString *const QDKeyTag = @"dev.quackduck.mobile-auth-key-v1";
static NSString *const QDIdentityAccount = @"mobile-auth-identity-v1";

static void QDRecord(NSString *line) {
    const char *path = getenv("QD_SENTINEL");
    if (!path) return;
    FILE *file = fopen(path, "a");
    if (!file) return;
    fprintf(file, "%s\n", line.UTF8String);
    fclose(file);
}

static void QDPrepareRecord(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *sentinel = [documents stringByAppendingPathComponent:@"java-ok.txt"];
    setenv("QD_SENTINEL", sentinel.UTF8String, 1);
    FILE *file = fopen(sentinel.UTF8String, "w");
    if (file) fclose(file);
}

static NSString *QDBase64URL(NSData *data) {
    NSString *value = [data base64EncodedStringWithOptions:0];
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    value = [value stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [value stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"="]];
}

static NSString *QDAppVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
}

static BOOL QDValidVersion(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 32)
        return NO;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"0123456789."].invertedSet;
    if ([value rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    for (NSString *part in [value componentsSeparatedByString:@"."])
        if (!part.length) return NO;
    return YES;
}

static NSData *QDDecodeBase64URL(NSString *value) {
    value = [value stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    value = [value stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (value.length % 4) value = [value stringByAppendingString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:value options:0];
}

static NSData *QDKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"dev.quackduck.runelite",
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    return SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess
        ? CFBridgingRelease(result) : nil;
}

static BOOL QDKeychainWrite(NSString *account, NSData *data) {
    NSDictionary *key = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"dev.quackduck.runelite",
        (__bridge id)kSecAttrAccount: account
    };
    NSDictionary *change = @{(__bridge id)kSecValueData: data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)key,
                                    (__bridge CFDictionaryRef)change);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [key mutableCopy];
        insert[(__bridge id)kSecValueData] = data;
        insert[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    return status == errSecSuccess;
}

static void QDSaveIdentity(NSDictionary *identity) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
    if (!json) return;
    QDKeychainWrite(QDIdentityAccount, json);
    [NSUserDefaults.standardUserDefaults setObject:json forKey:QDIdentityAccount];
}

static NSMutableDictionary *QDIdentity(void) {
    NSData *stored = QDKeychainRead(QDIdentityAccount);
    if (!stored) stored = [NSUserDefaults.standardUserDefaults objectForKey:QDIdentityAccount];
    NSDictionary *identity = stored ? [NSJSONSerialization JSONObjectWithData:stored
        options:0 error:nil] : nil;
    if ([identity[@"installationId"] isKindOfClass:NSString.class]) {
        return [identity mutableCopy];
    }
    NSMutableDictionary *created = [@{
        @"installationId": [@"mobile-ios-" stringByAppendingString:NSUUID.UUID.UUIDString],
        @"sequence": @0
    } mutableCopy];
    QDSaveIdentity(created);
    return created;
}

static SecKeyRef QDPrivateKey(void) {
    NSData *tag = [QDKeyTag dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrApplicationTag: tag,
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecReturnRef: @YES
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess)
        return (SecKeyRef)result;
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *fallbackPath = [documents stringByAppendingPathComponent:@"qd-device-key.bin"];
    NSData *stored = [NSData dataWithContentsOfFile:fallbackPath];
    NSDictionary *rawAttributes = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
        (__bridge id)kSecAttrKeySizeInBits: @256
    };
    if (stored.length) {
        SecKeyRef restored = SecKeyCreateWithData((__bridge CFDataRef)stored,
            (__bridge CFDictionaryRef)rawAttributes, NULL);
        if (restored) return restored;
    }
    NSDictionary *attributes = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeySizeInBits: @256,
        (__bridge id)kSecPrivateKeyAttrs: @{
            (__bridge id)kSecAttrIsPermanent: @YES,
            (__bridge id)kSecAttrApplicationTag: tag,
            (__bridge id)kSecAttrAccessible:
                (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    };
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error);
    if (!key) {
        NSDictionary *ephemeralAttributes = @{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
            (__bridge id)kSecAttrKeySizeInBits: @256
        };
        key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)ephemeralAttributes, NULL);
        NSData *raw = key ? CFBridgingRelease(SecKeyCopyExternalRepresentation(key, NULL)) : nil;
        if (raw.length) {
            [raw writeToFile:fallbackPath options:NSDataWritingFileProtectionComplete error:nil];
        }
    }
    if (!key) {
        NSLog(@"QD_IOS: device key error %@", error ? (__bridge NSError *)error : nil);
        QDRecord(@"AUTH_KEY_FAILED");
    }
    if (error) CFRelease(error);
    return key;
}

static NSData *QDPublicKey(SecKeyRef privateKey) {
    SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
    NSData *raw = publicKey ? CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, NULL)) : nil;
    if (publicKey) CFRelease(publicKey);
    const unsigned char prefix[] = {
        0x30,0x59,0x30,0x13,0x06,0x07,0x2A,0x86,0x48,0xCE,0x3D,0x02,0x01,
        0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,0x07,0x03,0x42,0x00
    };
    NSMutableData *x509 = [NSMutableData dataWithBytes:prefix length:sizeof(prefix)];
    if (raw) [x509 appendData:raw];
    return raw.length == 65 ? x509 : nil;
}

static NSData *QDTranscript(NSString *domain, NSArray<NSString *> *values) {
    NSUInteger domainBytes = [domain lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray *parts = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"%lu:%@", (unsigned long)domainBytes, domain]];
    for (NSString *value in values) {
        NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [parts addObject:[NSString stringWithFormat:@"%lu:%@", (unsigned long)bytes, value]];
    }
    return [[parts componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *QDSign(SecKeyRef key, NSData *message) {
    CFErrorRef error = NULL;
    NSData *signature = CFBridgingRelease(SecKeyCreateSignature(key,
        kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
        (__bridge CFDataRef)message, &error));
    if (error) CFRelease(error);
    return signature ? QDBase64URL(signature) : nil;
}

static NSString *QDNonce(void) {
    unsigned char bytes[24];
    SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes);
    return QDBase64URL([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}

static NSDictionary *QDPost(NSDictionary *body, NSError **failure) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:QDAuthURL]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:failure];
    if (!request.HTTPBody) return nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *responseData;
    __block NSError *requestError;
    __block NSInteger status;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            requestError = error;
            status = [(NSHTTPURLResponse *)response statusCode];
            dispatch_semaphore_signal(done);
        }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    NSDictionary *json = responseData ? [NSJSONSerialization JSONObjectWithData:responseData
        options:0 error:nil] : nil;
    if (requestError || status < 200 || status > 299 || !json) {
        NSString *message = json[@"error"] ?: requestError.localizedDescription ?: @"QuackDuck did not respond";
        if (failure) *failure = [NSError errorWithDomain:@"QuackDuck" code:status
            userInfo:@{NSLocalizedDescriptionKey: message}];
        return nil;
    }
    return json;
}

static NSDictionary *QDVerifyEnvelope(NSDictionary *envelope, NSError **failure) {
    NSData *payload = QDDecodeBase64URL(envelope[@"payload"]);
    NSData *signature = QDDecodeBase64URL(envelope[@"signature"]);
    NSData *serverX509 = [[NSData alloc] initWithBase64EncodedString:QDServerPublicKey options:0];
    BOOL metadata = [envelope[@"type"] isEqual:@"signed"] &&
        [envelope[@"algorithm"] isEqual:@"ES256"] &&
        [envelope[@"keyId"] isEqual:@"session-server-v1"];
    if (metadata && serverX509.length == 91 && payload && signature) {
        NSData *raw = [serverX509 subdataWithRange:NSMakeRange(26, 65)];
        NSDictionary *attributes = @{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
            (__bridge id)kSecAttrKeySizeInBits: @256
        };
        SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)raw,
                                             (__bridge CFDictionaryRef)attributes, NULL);
        BOOL valid = key && SecKeyVerifySignature(key,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)payload, (__bridge CFDataRef)signature, NULL);
        if (key) CFRelease(key);
        if (valid) return [NSJSONSerialization JSONObjectWithData:payload options:0 error:failure];
    }
    if (failure) *failure = [NSError errorWithDomain:@"QuackDuck" code:0
        userInfo:@{NSLocalizedDescriptionKey: @"QuackDuck signature verification failed"}];
    return nil;
}

static NSDictionary *QDRefresh(NSString *pairingCode, NSError **failure) {
    NSMutableDictionary *identity = QDIdentity();
    SecKeyRef key = QDPrivateKey();
    NSData *publicKey = key ? QDPublicKey(key) : nil;
    if (!key || !publicKey) {
        if (key) CFRelease(key);
        if (failure) *failure = [NSError errorWithDomain:@"QuackDuck" code:0
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create the device identity"}];
        return nil;
    }
    NSString *installation = identity[@"installationId"];
    NSString *version = QDAppVersion();
    long long timestamp = (long long)(NSDate.date.timeIntervalSince1970 * 1000);
    NSString *nonce = QDNonce();
    NSMutableDictionary *request;
    if (pairingCode.length) {
        NSString *public64 = [publicKey base64EncodedStringWithOptions:0];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(publicKey.bytes, (CC_LONG)publicKey.length, digest);
        NSString *fingerprint = QDBase64URL([NSData dataWithBytes:digest length:sizeof(digest)]);
        request = [@{
            @"action": @"pair", @"code": pairingCode,
            @"installationId": installation, @"deviceFingerprint": fingerprint,
            @"devicePublicKey": public64, @"appVersion": version,
            @"timestamp": @(timestamp), @"nonce": nonce
        } mutableCopy];
        request[@"signature"] = QDSign(key, QDTranscript(@"QD_MOBILE_PAIR_V1", @[
            pairingCode, installation, fingerprint, public64, version,
            [@(timestamp) stringValue], nonce
        ]));
    } else {
        long long sequence = [identity[@"sequence"] longLongValue] + 1;
        identity[@"sequence"] = @(sequence);
        QDSaveIdentity(identity);
        request = [@{
            @"action": @"status", @"installationId": installation,
            @"sequence": @(sequence), @"timestamp": @(timestamp),
            @"nonce": nonce, @"appVersion": version
        } mutableCopy];
        request[@"signature"] = QDSign(key, QDTranscript(@"QD_MOBILE_REQUEST_V1", @[
            @"status", installation, [@(sequence) stringValue],
            [@(timestamp) stringValue], nonce, version, @""
        ]));
    }
    CFRelease(key);
    if (!request[@"signature"]) return nil;
    NSDictionary *envelope = QDPost(request, failure);
    if (!envelope) return nil;
    NSDictionary *payload = QDVerifyEnvelope(envelope, failure);
    if (!payload) return nil;
    if (pairingCode.length) {
        if (![payload[@"type"] isEqual:@"mobile_pairing_complete"]) {
            if (failure) *failure = [NSError errorWithDomain:@"QuackDuck" code:0
                userInfo:@{NSLocalizedDescriptionKey: @"Unexpected pairing response"}];
            return nil;
        }
        return QDRefresh(nil, failure);
    }
    long long now = (long long)(NSDate.date.timeIntervalSince1970 * 1000);
    if (![payload[@"type"] isEqual:@"mobile_profile"] ||
        [payload[@"expiresAt"] longLongValue] <= now) {
        if (failure) *failure = [NSError errorWithDomain:@"QuackDuck" code:0
            userInfo:@{NSLocalizedDescriptionKey: @"QuackDuck returned an expired profile"}];
        return nil;
    }
    NSDictionary *profile = payload[@"result"];
    NSString *discord = [profile[@"discordName"] isKindOfClass:NSString.class]
        ? profile[@"discordName"] : @"";
    NSString *tier = [profile[@"tier"] isKindOfClass:NSString.class]
        ? profile[@"tier"] : @"free";
    return @{
        @"authorized": @([profile[@"accessActive"] boolValue]),
        @"discordName": discord,
        @"tier": tier
    };
}

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

@interface QDKeyboardView : UIView <UIKeyInput>
@end

@implementation QDKeyboardView
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDone; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}
- (void)insertText:(NSString *)text {
    if ([text isEqualToString:@"\n"] || [text isEqualToString:@"\r"]) {
        QDSendKey(10);
        [self resignFirstResponder];
        return;
    }
    for (NSUInteger i = 0; i < text.length; i++) {
        QDSendInput(QDInputChar, [text characterAtIndex:i], 0, 0, 0);
    }
}
- (void)deleteBackward { QDSendKey(8); }
@end

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

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) QDSurfaceView *surface;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) QDKeyboardView *keyboard;
@property(nonatomic, strong) UIButton *shiftButton;
@property(nonatomic, strong) UIButton *controlButton;
@property(nonatomic, strong) UIButton *altButton;
@property(nonatomic) BOOL shiftDown;
@property(nonatomic) BOOL controlDown;
@property(nonatomic) BOOL altDown;
@property(nonatomic, strong) dispatch_source_t urlTimer;
@property(nonatomic) BOOL authCheckRunning;
@property(nonatomic) BOOL awaitingPairCode;
@property(nonatomic) BOOL updateBlocked;
@property(nonatomic) BOOL javaStarted;
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
    QDPrepareRecord();
    NSCAssert([QDTranscript(@"D", @[@"x"]) isEqualToData:
        [@"1:D\n1:x" dataUsingEncoding:NSUTF8StringEncoding]],
        @"QuackDuck auth transcript mismatch");
    NSCAssert(QDValidVersion(@"0.3") && !QDValidVersion(@"0..3"),
        @"QuackDuck version validation mismatch");
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

    self.keyboard = [[QDKeyboardView alloc] initWithFrame:CGRectMake(1, 1, 2, 2)];
    self.keyboard.backgroundColor = UIColor.clearColor;
    self.keyboard.accessibilityElementsHidden = YES;
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
    self.surface.firstFrame = ^{
        weakSelf.status.hidden = YES;
    };
    [self checkMandatoryUpdate];
    return YES;
}

- (void)checkMandatoryUpdate {
    self.updateBlocked = NO;
    self.status.hidden = NO;
    self.status.text = @"Checking for QuackDuck updates…";
    NSString *url = [NSString stringWithFormat:@"%@?t=%.0f", QDLatestPlistURL,
                     NSDate.date.timeIntervalSince1970];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 10;
    [request setValue:@"no-store" forHTTPHeaderField:@"cache-control"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *plist = data.length <= 65536 ?
                [NSPropertyListSerialization propertyListWithData:data options:0
                    format:nil error:nil] : nil;
            NSString *latest = [plist isKindOfClass:NSDictionary.class]
                ? plist[@"CFBundleShortVersionString"] : nil;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || status != 200 || !QDValidVersion(latest)) {
                    [self blockForUpdate:@"The current release could not be verified. Check your connection and try again."];
                    return;
                }
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                NSString *highest = [defaults stringForKey:@"qd-highest-ios-version"];
                if (QDValidVersion(highest) &&
                    [latest compare:highest options:NSNumericSearch] == NSOrderedAscending) {
                    [self blockForUpdate:@"The QuackDuck release channel moved backwards and cannot be trusted."];
                    return;
                }
                if (!highest || [latest compare:highest options:NSNumericSearch] == NSOrderedDescending) {
                    [defaults setObject:latest forKey:@"qd-highest-ios-version"];
                }
                if ([latest compare:QDAppVersion() options:NSNumericSearch] == NSOrderedDescending) {
                    [self blockForUpdate:[NSString stringWithFormat:
                        @"QuackDuck %@ is required before RuneLite can start.", latest]];
                    return;
                }
                QDRecord(@"UPDATE_GATE_OK");
                self.updateBlocked = NO;
                [self checkQuackDuckAuth];
            });
        }] resume];
}

- (void)blockForUpdate:(NSString *)message {
    self.updateBlocked = YES;
    self.status.hidden = NO;
    self.status.text = message;
    if (self.window.rootViewController.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"QuackDuck update"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open update page"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:QDAccountURL]
                options:@{} completionHandler:nil];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Check again"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self checkMandatoryUpdate];
        }]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)checkQuackDuckAuth {
    if (self.authCheckRunning || self.javaStarted) return;
    self.authCheckRunning = YES;
    self.status.hidden = NO;
    self.status.text = @"Checking QuackDuck access…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *profile = QDRefresh(nil, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.authCheckRunning = NO;
            if ([profile[@"authorized"] boolValue]) [self startRuneLite];
            else {
                self.status.text = @"QuackDuck sign-in is required.";
                [self presentQuackDuckLogin:error.localizedDescription];
#if TARGET_OS_SIMULATOR
                if (getenv("QD_TEST_ALLOW_UNAUTH")) [self startRuneLite];
#endif
            }
        });
    });
}

- (void)startRuneLite {
    if (self.javaStarted) return;
    self.javaStarted = YES;
    self.status.text = @"Starting RuneLite…";
    [self.surface startDisplayLoop];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = RunJava(self.surface.pixelWidth, self.surface.pixelHeight);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.hidden = NO;
            self.status.text = result;
        });
    });
}

- (void)presentQuackDuckLogin:(NSString *)detail {
    NSLog(@"QD_IOS: QuackDuck auth prompt");
    QDRecord(@"AUTH_PROMPT_OK");
    NSString *message = detail.length
        ? [@"Sign in with Discord, then enter the pairing code.\n\n" stringByAppendingString:detail]
        : @"Sign in with Discord, then enter the pairing code shown on your QuackDuck account.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        @"Link your QuackDuck account" message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Enter Code"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self presentPairCode];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Login with Discord"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            self.awaitingPairCode = YES;
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:QDAccountURL]
                options:@{} completionHandler:nil];
        }]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)presentPairCode {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Pair device"
        message:@"Enter the code shown on quackduck.dev/mobile."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Pairing code";
        field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Pair"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *code = alert.textFields.firstObject.text.uppercaseString;
            NSCharacterSet *invalid = [NSCharacterSet alphanumericCharacterSet].invertedSet;
            code = [[code componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@""];
            [self pairQuackDuck:code];
        }]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

- (void)pairQuackDuck:(NSString *)code {
    if (code.length < 8 || code.length > 32) {
        [self presentQuackDuckLogin:@"That pairing code is not valid."];
        return;
    }
    self.status.hidden = NO;
    self.status.text = @"Linking QuackDuck…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *profile = QDRefresh(code, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.hidden = YES;
            NSString *name = profile[@"discordName"];
            NSString *message = [profile[@"authorized"] boolValue]
                ? [NSString stringWithFormat:@"Linked as %@.", name.length ? name : @"Discord user"]
                : (error.localizedDescription ?: @"This account does not currently have mobile access.");
            UIAlertController *result = [UIAlertController alertControllerWithTitle:
                ([profile[@"authorized"] boolValue] ? @"QuackDuck linked" : @"Unable to link")
                message:message preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    if ([profile[@"authorized"] boolValue]) [self startRuneLite];
                    else [self presentQuackDuckLogin:nil];
                }]];
            [self.window.rootViewController presentViewController:result animated:YES completion:nil];
        });
    });
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if (self.awaitingPairCode) {
        self.awaitingPairCode = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ [self presentPairCode]; });
    } else if (self.updateBlocked) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self checkMandatoryUpdate]; });
    }
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
    else {
        [self.window makeKeyWindow];
        [self.keyboard becomeFirstResponder];
        [self.keyboard reloadInputViews];
    }
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
