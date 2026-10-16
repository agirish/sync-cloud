#import "TestProcessTextChecking.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static BOOL quiet = NO;

BOOL TestProcessTextCheckingIsQuiet(void) {
    return quiet;
}

static NSOrthography *QuietOrthography(void) {
    return [NSOrthography defaultOrthographyForLanguage:@"en"];
}

/// `-checkString:range:types:options:inSpellDocumentWithTag:orthography:wordCount:` — the
/// synchronous check, which a text view resigning first responder runs on the main thread.
static NSArray<NSTextCheckingResult *> *QuietCheckString(
    id self, SEL _cmd, NSString *string, NSRange range, NSTextCheckingTypes types,
    NSDictionary<NSTextCheckingOptionKey, id> *options, NSInteger tag,
    NSOrthography *__autoreleasing *orthography, NSInteger *wordCount)
{
    if (orthography) *orthography = QuietOrthography();
    if (wordCount) *wordCount = 0;
    return @[];
}

/// `-requestCheckingOfString:range:types:options:inSpellDocumentWithTag:completionHandler:` — the
/// asynchronous check, which AppKit otherwise runs as an `NSTextCheckingOperation` holding the
/// lock. The handler is still called, on a background queue as AppKit's is, so a controller
/// waiting for its answer gets one.
static NSInteger QuietRequestChecking(
    id self, SEL _cmd, NSString *string, NSRange range, NSTextCheckingTypes types,
    NSDictionary<NSTextCheckingOptionKey, id> *options, NSInteger tag,
    void (^handler)(NSInteger, NSArray<NSTextCheckingResult *> *, NSOrthography *, NSInteger))
{
    static _Atomic NSInteger lastSequenceNumber = 0;
    NSInteger sequenceNumber = atomic_fetch_add(&lastSequenceNumber, 1) + 1;
    if (handler) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            handler(sequenceNumber, @[], QuietOrthography(), 0);
        });
    }
    return sequenceNumber;
}

static BOOL Replace(SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(NSSpellChecker.class, selector);
    if (!method) return NO;
    method_setImplementation(method, replacement);
    return YES;
}

/// Runs when the test bundle is loaded — by `swiftpm-testing-helper`, or by XCTest injecting the
/// bundle into its host — so before any test can mount a view. In-process only.
__attribute__((constructor))
static void TestProcessTextCheckingQuietTheSpellChecker(void) {
    BOOL checks = Replace(@selector(checkString:range:types:options:inSpellDocumentWithTag:orthography:wordCount:),
                          (IMP)QuietCheckString);
    BOOL requests = Replace(@selector(requestCheckingOfString:range:types:options:inSpellDocumentWithTag:completionHandler:),
                            (IMP)QuietRequestChecking);
    quiet = checks && requests;
}
