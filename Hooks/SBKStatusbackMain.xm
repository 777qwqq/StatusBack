// StatusBack — universal "back" for iOS 16 rootless.
//
// Tapping the left or right half of the status bar posts a Darwin
// notification. Every injected process performs exactly one back step
// (accessibility escape -> pop navigation stack -> dismiss modal -> pop self
// from its own stack). When nothing is left to pop, the tweak asks
// SpringBoard to go home.
//
// The trigger is implemented by filtering UIApplication's sendEvent:. The
// system status bar lives in its own window above the app's window, so an
// overlay added to the app window can never receive status bar touches —
// but every touch in the app, status bar included, flows through
// sendEvent:. The hit test uses the real status bar frame instead of a
// hard-coded height, so notch and Dynamic Island devices work too.

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

static BOOL sbk_statusback_IsSpringBoard(void) {
    static BOOL isSpringBoard;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isSpringBoard = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
    });
    return isSpringBoard;
}

// Returns YES when the touch lands inside the status bar and the configured
// side matches.
static BOOL sbk_statusback_ShouldTriggerForTouches(NSSet<UITouch *> *touches) {
    SBKStatusbackConfig *config = [SBKStatusbackConfig sbk_statusback_shared];
    if (![config sbk_statusback_isEnabled]) return NO;

    SBKStatusbackTriggerSide side = [config sbk_statusback_triggerSide];
    if (side == SBKStatusbackTriggerSideNone) return NO;

    if (sbk_statusback_IsSpringBoard()) return NO;

    UITouch *touch = [touches anyObject];
    if (!touch) return NO;

    // locationInWindow gives coordinates in the touch's own window, which for
    // status bar touches is the status bar window — its origin is the screen
    // origin, so the y value is directly comparable to statusBarFrame.
    UIWindow *touchWindow = touch.window;
    if (!touchWindow) return NO;

    UIWindowScene *scene = (UIWindowScene *)touchWindow.windowScene;
    if (!scene || !scene.statusBarManager) return NO;
    CGRect statusBarFrame = scene.statusBarManager.statusBarFrame;
    if (CGRectIsEmpty(statusBarFrame)) return NO;

    CGPoint point = [touch locationInView:touchWindow];
    if (!CGRectContainsPoint(statusBarFrame, point)) return NO;

    // Only the left or right half, per the preference.
    BOOL isLeft = point.x < statusBarFrame.size.width / 2.0;
    if (side == SBKStatusbackTriggerSideLeft && !isLeft) return NO;
    if (side == SBKStatusbackTriggerSideRight && isLeft) return NO;

    return YES;
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

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;

    if (event.type != UIEventTypeTouches) return;
    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count == 0) return;

    // Only react to the end of a single tap, and only when the touch began
    // inside the status bar (so dragging out of the status bar does not fire).
    UITouch *touch = [touches anyObject];
    if (touch.phase != UITouchPhaseEnded) return;
    if (touches.count != 1) return;

    if (sbk_statusback_ShouldTriggerForTouches(touches)) {
        sbk_statusback_PostTrigger();
    }
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
    NSMethodSignature *signature = [sb methodSignatureForSelector:homeSelector];
    if (!signature) return;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = sb;
    invocation.selector = homeSelector;
    dispatch_async(dispatch_get_main_queue(), ^{
        [invocation invoke];
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
