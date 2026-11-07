#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SBKStatusbackTriggerSide) {
    SBKStatusbackTriggerSideNone = 0,
    SBKStatusbackTriggerSideLeft = 1,
    SBKStatusbackTriggerSideRight = 2,
    SBKStatusbackTriggerSideBoth = 3,
};

typedef NS_ENUM(NSInteger, SBKStatusbackFallbackBehavior) {
    SBKStatusbackFallbackBehaviorPopOnly = 0,   // never leave the app
    SBKStatusbackFallbackBehaviorHome = 1,      // go home when the stack is at its root
};

@interface SBKStatusbackConfig : NSObject
+ (instancetype)sbk_statusback_shared;
- (BOOL)sbk_statusback_isEnabled;
- (SBKStatusbackTriggerSide)sbk_statusback_triggerSide;
- (SBKStatusbackFallbackBehavior)sbk_statusback_fallbackBehavior;
- (BOOL)sbk_statusback_showStatusIcon;
- (void)sbk_statusback_reload;
@end
