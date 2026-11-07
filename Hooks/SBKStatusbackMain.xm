#pragma once

// StatusBack — universal "back" for iOS 16 rootless.
//
// Tapping the left or right half of the status bar posts a Darwin
// notification. Every injected process performs exactly one back step
// (accessibility escape -> pop navigation stack -> dismiss modal -> pop self
// from its own stack). When nothing is left to pop, the tweak asks
// SpringBoard to go home.
//
// The status bar strip is a plain UIKit overlay installed by this tweak, so
// it cannot be confused with a control drawn by the host app. It only claims
// touches that land inside the status bar rectangle and hit nothing else.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SBKStatusbackConfig.h"
#import "SBKStatusbackPrivate.h"
#import "SBKStatusbackPreferences.h"

static NSString * const SBKStatusbackTriggerNotification = @"com.catpaw.statusback.trigger";
static NSString * const SBKStatusbackHomeNotification = @"com.catpaw.statusback.gohome";

static void sbk_statusback_HandleHomeNotification(CFNotificationCenterRef center,
                                                  void *observer, CFStringRef name,
                                                  const void *object, CFDictionaryRef info);
static void sbk_statusback_HandleTriggerCallback(CFNotificationCenterRef center,
                                                void *observer, CFStringRef name,
                                                const void *object, CFDictionaryRef info);

#pragma mark - Shared helpers

static UIWindow * sbk_statusback_KeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
        for (UIWindow *window in windowScene.windows) {
            if (window.windowLevel == UIWindowLevelNormal && !window.hidden) return window;
        }
    }
    return nil;
}

static void sbk_statusback_PostHome(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)SBKStatusbackHomeNotification, NULL, NULL, true);
}

static void sbk_statusback_PostTrigger(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)SBKStatusbackTriggerNotification, NULL, NULL, true);
}

#pragma mark - Status bar overlay

@interface SBKStatusbackStatusBarTapView : UIView
@end

@implementation SBKStatusbackStatusBarTapView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Only claim taps in the top strip; everything else falls through.
    if (point.y > 44.0) return nil;
    return [super hitTest:point withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    SBKStatusbackConfig *config = [SBKStatusbackConfig sbk_statusback_shared];
    if (![config sbk_statusback_isEnabled]) return;

    SBKStatusbackTriggerSide side = [config sbk_statusback_triggerSide];
    if (side == SBKStatusbackTriggerSideNone) return;

    CGFloat width = self.bounds.size.width;
    if (width <= 0) return;

    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    BOOL isLeft = point.x < width / 2.0;

    if ((side == SBKStatusbackTriggerSideLeft && !isLeft) || (side == SBKStatusbackTriggerSideRight && isLeft)) {
        return;
    }

    sbk_statusback_PostTrigger();
    [super touchesBegan:touches withEvent:event];
}

@end

static BOOL sbk_statusback_IsSpringBoard(void) {
    static BOOL isSpringBoard;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isSpringBoard = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
    });
    return isSpringBoard;
}

static void sbk_statusback_InstallStatusBarOverlay(void) {
    if (![[SBKStatusbackConfig sbk_statusback_shared] sbk_statusback_isEnabled]) return;
    // SpringBoard only needs to handle the home notification; putting a tap
    // overlay on its status bar would swallow system gestures.
    if (sbk_statusback_IsSpringBoard()) return;
    UIWindow *window = sbk_statusback_KeyWindow();
    if (!window) return;

    static NSString * const kOverlayKey = @"SBKStatusbackStatusBarTapView";
    if (objc_getAssociatedObject(window, (__bridge const void *)kOverlayKey)) return;

    SBKStatusbackStatusBarTapView *overlay = [[SBKStatusbackStatusBarTapView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    overlay.userInteractionEnabled = YES;
    [window addSubview:overlay];
    objc_setAssociatedObject(window, (__bridge const void *)kOverlayKey, overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Back action

static BOOL sbk_statusback_PerformBackOnViewController(UIViewController *controller) {
    if (!controller) return NO;

    // 1) Accessibility escape — the system "back" gesture. Most modals,
    //    menus and action sheets implement it.
    if ([controller respondsToSelector:@selector(accessibilityPerformEscape)] &&
        sbk_statusback_OverridesSelector([controller class], @selector(accessibilityPerformEscape))) {
        if ([controller accessibilityPerformEscape]) return YES;
    }

    // 2) Pop the deepest navigation controller in the subtree.
    UINavigationController *nav = [controller sbk_statusback_deepestNavigationController];
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        return YES;
    }

    // 3) Dismiss a presented view controller.
    if (controller.presentedViewController) {
        [controller dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }

    // 4) Pop the controller itself when it lives in a navigation stack.
    if ([controller isKindOfClass:[UINavigationController class]]) {
        UINavigationController *selfNav = (UINavigationController *)controller;
        if (selfNav.viewControllers.count > 1) {
            [selfNav popViewControllerAnimated:YES];
            return YES;
        }
    }

    return NO;
}

#pragma mark - Hooks

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, (CFNotificationCallback)sbk_statusback_HandleHomeNotification,
        (__bridge CFStringRef)SBKStatusbackHomeNotification, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

%end

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    sbk_statusback_InstallStatusBarOverlay();
}

%end

static void sbk_statusback_HandleHomeNotification(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object,
                                      CFDictionaryRef info) {
    Class sbClass = NSClassFromString(@"SpringBoard");
    if (!sbClass) return;
    id sb = [sbClass sharedApplication];
    // The selector name differs across iOS releases; goToHomeScreen is the
    // modern one, goHome is the older fallback.
    SEL homeSelector = NSSelectorFromString(@"goToHomeScreen");
    if (![sb respondsToSelector:homeSelector]) {
        homeSelector = NSSelectorFromString(@"goHome");
        if (![sb respondsToSelector:homeSelector]) return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [sb performSelector:homeSelector];
    });
}

static void sbk_statusback_HandleTriggerCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SBKStatusbackConfig *config = [SBKStatusbackConfig sbk_statusback_shared];
        if (![config sbk_statusback_isEnabled]) return;
        // SpringBoard has no app navigation stack; let the home notification
        // handle the fallback instead of walking its view hierarchy.
        if (sbk_statusback_IsSpringBoard()) return;

        UIWindow *window = sbk_statusback_KeyWindow();
        UIViewController *root = window.rootViewController;
        if (!root) {
            if ([config sbk_statusback_fallbackBehavior] == SBKStatusbackFallbackBehaviorHome) sbk_statusback_PostHome();
            return;
        }
        if (sbk_statusback_PerformBackOnViewController(root)) return;
        if ([config sbk_statusback_fallbackBehavior] == SBKStatusbackFallbackBehaviorHome) sbk_statusback_PostHome();
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, (CFNotificationCallback)sbk_statusback_HandleTriggerCallback,
        (__bridge CFStringRef)SBKStatusbackTriggerNotification, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
