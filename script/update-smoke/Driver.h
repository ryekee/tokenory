#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// Test-only replacement for Sparkle's UI. The production UpdateChecker owns the updater.
@interface UpdateSmokeDriver : NSObject <SPUUserDriver>
@property BOOL expectUpdate;
@end
