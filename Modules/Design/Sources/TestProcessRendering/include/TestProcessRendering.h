#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// **Test-only. The app never links this.** Linking it into a test bundle is the whole interface:
/// a constructor in it runs when the bundle loads, before any test, and registers
/// `com.apple.SwiftUI.DisableAsyncRendering` as YES in the process's registration domain. SwiftUI
/// reads that key once, the first time a hosting view could render, so every `NSHostingView` in
/// the process then draws its animations on the main thread and none from SwiftUI's display-link
/// thread.
///
/// Why: a display-link render that needs the main thread holds SwiftUI's update lock and waits for
/// main. If main is then tearing down a table row with a hosting view in it, the removal asks for
/// that lock and runs the waiting update right there, inside the row's `dealloc`. The update walks
/// up the hosting view's focus parents to the dying row and takes a weak reference to it, and the
/// runtime aborts the process. `docs/flaky-tests.md` ▸ *A table row's teardown runs SwiftUI's
/// display-link update, which takes a weak reference to the dying row* has the stacks.
///
/// No test reads how SwiftUI renders: a frame drawn on main is the same frame.
///
/// Whether async rendering is off in this process, as SwiftUI will read it. The guard tests read
/// this, and through it link the target.
BOOL TestProcessRenderingIsOnMain(void);

NS_ASSUME_NONNULL_END
