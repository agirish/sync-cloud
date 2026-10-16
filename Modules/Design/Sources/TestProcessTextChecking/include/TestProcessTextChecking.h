#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// **Test-only. The app never links this.** Linking it into a test bundle is the whole interface:
/// a constructor in it runs when the bundle loads, before any test, and replaces the two
/// `NSSpellChecker` methods every text check goes through — `checkString:range:types:options:…`
/// and `requestCheckingOfString:range:types:options:…` — with ones that find nothing and never
/// take the spell checker's lock.
///
/// Why: a text view resigning with a check pending waits for that lock, and the spell checker's
/// own thread can be delivering another process's defaults change to SwiftUI while it holds it —
/// a deadlock. Every SwiftUI `TextField` a test types into schedules such a check, and no setting
/// stops it: measured, every check guesses the text's language, which reads preferences, whatever
/// its types, even none. `docs/flaky-tests.md` ▸ *A spell check and a defaults change from another
/// process deadlock a SwiftUI focus move* has the stacks and the counts.
///
/// No test reads what the checker finds: the editors and the typing fixtures already turn every
/// substitution off, and the spelling tests read the setting, not underlines.
///
/// Whether the replacement is in. The guard tests read this, and through it link the target.
BOOL TestProcessTextCheckingIsQuiet(void);

NS_ASSUME_NONNULL_END
