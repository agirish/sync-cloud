#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "dropbox" asset catalog image resource.
static NSString * const ACImageNameDropbox AC_SWIFT_PRIVATE = @"dropbox";

/// The "googledrive" asset catalog image resource.
static NSString * const ACImageNameGoogledrive AC_SWIFT_PRIVATE = @"googledrive";

/// The "icloud" asset catalog image resource.
static NSString * const ACImageNameIcloud AC_SWIFT_PRIVATE = @"icloud";

/// The "onedrive" asset catalog image resource.
static NSString * const ACImageNameOnedrive AC_SWIFT_PRIVATE = @"onedrive";

#undef AC_SWIFT_PRIVATE
