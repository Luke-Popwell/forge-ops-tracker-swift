#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Test-only helper, not shipped as part of the library: raises and catches an NSException via
 * @try/@throw/@catch so its -callStackSymbols is actually populated (confirmed directly: merely
 * constructing an NSException without raising it leaves -callStackSymbols empty). This has to be
 * Objective-C, not Swift: Swift's do/catch cannot catch an NSException at all (it's a
 * completely separate mechanism from Swift's own Error/throw), so a Swift test file calling
 * -raise directly would crash the whole test process rather than being caught. Same reasoning as
 * this repo's own Objective-C client's own test helper (sdks/objc/Tests/FOTEventBuilderTests.m's
 * -raiseAndCatch), just factored out so the Swift test target can call it.
 */
FOUNDATION_EXPORT NSException *FOTRaiseAndCatchTestException(NSString *name, NSString *reason);

NS_ASSUME_NONNULL_END
