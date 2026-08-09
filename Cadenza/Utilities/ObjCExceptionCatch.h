#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block and catches any Objective-C exception (NSException).
/// Returns YES if the block executed without exception, NO otherwise.
FOUNDATION_EXPORT BOOL ObjCExceptionCatch(void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
