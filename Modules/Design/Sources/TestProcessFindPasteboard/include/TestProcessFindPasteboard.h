#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// **Test-only. The app never links this.** Linking it into a test bundle is the whole interface:
/// a constructor in it runs when the bundle loads, before any test, and replaces
/// `+[NSPasteboard pasteboardWithName:]` with one that answers a request for the Find pasteboard
/// with a board of this process's own, named for its pid. Every other name passes through.
///
/// Why: the Find pasteboard is one board for the whole machine, and `NSTextFinder` reads and writes
/// it through that method — measured, nine times for one Use Selection for Find and one Show Find.
/// Another test process writing it (`LineEndingPathsTests` puts `"one"` and `"on"` there) lands
/// between one test's seeding of the find bar and its read of the field, and the field holds the
/// other process's word. `docs/flaky-tests.md` ▸ *A named NSPasteboard is machine-global, so two
/// test PROCESSES share it* has the measurements.
///
/// No test needs another process's search string: each find-bar test seeds its own.
///
/// The name this process's find bars use. The guard tests read this, and through it link the target.
NSString *TestProcessFindPasteboardName(void);

NS_ASSUME_NONNULL_END
