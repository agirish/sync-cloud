#import "TestProcessFindPasteboard.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString *privateName = nil;
static NSPasteboard *(*original)(id, SEL, NSPasteboardName) = NULL;

NSString *TestProcessFindPasteboardName(void) {
    return privateName ?: NSPasteboardNameFind;
}

static NSPasteboard *PrivateFind(id self, SEL _cmd, NSPasteboardName name) {
    if (privateName && [name isEqualToString:NSPasteboardNameFind]) name = privateName;
    return original(self, _cmd, name);
}

/// The pasteboard server keeps a named board until someone releases it, so the process gives its
/// own back as it exits rather than leave one per test run.
static void ReleasePrivateFind(void) {
    if (privateName) [original(NSPasteboard.class, @selector(pasteboardWithName:), privateName) releaseGlobally];
}

/// Runs when the test bundle is loaded — by `swiftpm-testing-helper`, or by XCTest injecting the
/// bundle into its host — so before any test can open a find bar. In-process only.
__attribute__((constructor))
static void TestProcessFindPasteboardMakeItPrivate(void) {
    Method method = class_getClassMethod(NSPasteboard.class, @selector(pasteboardWithName:));
    if (!method) return;
    privateName = [NSString stringWithFormat:@"%@.SyncCloudTests.%d", NSPasteboardNameFind, getpid()];
    original = (NSPasteboard *(*)(id, SEL, NSPasteboardName))method_setImplementation(method, (IMP)PrivateFind);
    atexit(ReleasePrivateFind);
}
