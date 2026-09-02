#import "include/cfot_test_support.h"

NSException *FOTRaiseAndCatchTestException(NSString *name, NSString *reason) {
    @try {
        @throw [NSException exceptionWithName:name reason:reason userInfo:nil];
    } @catch (NSException *exception) {
        return exception;
    }
    return nil; // unreachable -- @throw always transfers to @catch above
}
