#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls CAFilter's runtime-only class factory behind an Objective-C exception
/// boundary. A missing class, selector, or exception returns nil.
FOUNDATION_EXPORT id _Nullable PeaklightTryCreateCAFilter(
    NSString *filterType
);

/// Reads a KVC value behind an Objective-C exception boundary.
FOUNDATION_EXPORT id _Nullable PeaklightTryValueForKey(
    id object,
    NSString *key
);

/// Writes a KVC value behind an Objective-C exception boundary.
FOUNDATION_EXPORT BOOL PeaklightTrySetValueForKey(
    id object,
    id _Nullable value,
    NSString *key
);

NS_ASSUME_NONNULL_END
