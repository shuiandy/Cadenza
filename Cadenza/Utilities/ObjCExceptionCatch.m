#import "ObjCExceptionCatch.h"

BOOL ObjCExceptionCatch(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[Cadenza] Caught ObjC exception: %@ — %@", exception.name, exception.reason);
        return NO;
    }
}
