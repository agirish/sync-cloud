#import "TestProcessRendering.h"

/// SwiftUI's own switch (`UserDefaultKeyedFeature` `DisableAsyncRendering`, macOS 27.0.1), read
/// from the standard defaults once and kept for the life of the process. The registration domain
/// counts: registered YES, `NSHostingView.startAsyncRendering()` never ran in a rig where, without
/// it, it ran at the first layout (2026-10-26).
static NSString *const DisableAsyncRendering = @"com.apple.SwiftUI.DisableAsyncRendering";

BOOL TestProcessRenderingIsOnMain(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:DisableAsyncRendering];
}

/// Runs when the test bundle is loaded — by `swiftpm-testing-helper`, or by XCTest injecting the
/// bundle into its host — so before any test can mount a view. The registration domain lives in
/// this process only: nothing is written to any defaults file.
__attribute__((constructor))
static void TestProcessRenderingRenderOnMain(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{ DisableAsyncRendering: @YES }];
}
