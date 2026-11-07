#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, SBKStatusbackFallbackBehavior) {
    SBKStatusbackFallbackBehaviorPopOnly = 0,   // never leave the app
    SBKStatusbackFallbackBehaviorHome = 1,      // go home when the stack is at its root
};

@interface SBKStatusbackConfig : NSObject
+ (instancetype)sbk_statusback_shared;
- (BOOL)sbk_statusback_isEnabled;
- (SBKStatusbackFallbackBehavior)sbk_statusback_fallbackBehavior;
- (BOOL)sbk_statusback_showFloatButton;
- (CGFloat)sbk_statusback_floatButtonAlpha;
- (CGFloat)sbk_statusback_floatButtonSize;
- (CGPoint)sbk_statusback_floatButtonPosition;
- (void)sbk_statusback_setFloatButtonPosition:(CGPoint)position;
- (void)sbk_statusback_reload;
@end
