// StatusBack — universal "back" for iOS 16 rootless.
//
// A draggable floating button is shown over the foreground app. Tapping it
// posts a Darwin notification; the foreground app performs one back step
// (accessibility escape -> pop navigation stack -> dismiss modal -> pop self
// from its own stack). When nothing is left to pop, the tweak asks
// SpringBoard to go home.
//
// The button lives in its own UIWindow above every app window, so it is never
// clipped or covered. Only the foreground app hosts a window at a time: each
// process creates its own when it becomes active and removes it when it
// resigns active, which keeps exactly one button on screen without any
// cross-process window sharing.

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
static void sbk_statusback_HandlePreferencesChanged(CFNotificationCenterRef center,
                                                   void *observer, CFStringRef name,
                                                   const void *object, CFDictionaryRef info);

static const void * const kSBKStatusbackButtonKey = &kSBKStatusbackButtonKey;
static NSString * const kSBKStatusbackWindowKey = @"SBKStatusbackButtonWindow";

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

// The scene that should host the floating button: the foreground active
// window scene, or nil when the app is in the background.
static UIWindowScene * sbk_statusback_HostScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateBackground) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

#pragma mark - Floating button

// A window that only forwards touches landing on the button; everything else
// passes through to the app underneath.
@interface SBKStatusbackButtonWindow : UIWindow
@end

@implementation SBKStatusbackButtonWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Returning nil makes the window transparent to touches, so taps outside
    // the button fall through to the app underneath. Returning the button
    // itself is what actually delivers the touch to its gesture recognizers.
    UIView *button = objc_getAssociatedObject(self, kSBKStatusbackButtonKey);
    if (![button isKindOfClass:[UIView class]]) return nil;
    if (button.hidden || button.alpha <= 0.01) return nil;
    if (!button.userInteractionEnabled) return nil;

    CGPoint local = [self convertPoint:point toView:button];
    if (!CGRectContainsPoint(button.bounds, local)) return nil;
    return button;
}

@end

@interface SBKStatusbackButtonView : UIView
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, assign) NSTimeInterval lastDragEnd;
@end

@implementation SBKStatusbackButtonView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = YES;

        UILabel *glyph = [[UILabel alloc] initWithFrame:self.bounds];
        glyph.text = @"‹";
        glyph.font = [UIFont boldSystemFontOfSize:frame.size.width * 0.55];
        glyph.textColor = [UIColor whiteColor];
        glyph.textAlignment = NSTextAlignmentCenter;
        glyph.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:glyph];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(sbk_statusback_handlePan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(sbk_statusback_handleTap:)];
        tap.numberOfTapsRequired = 1;
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)sbk_statusback_handleTap:(UIGestureRecognizer *)gesture {
    // A drag ends with the finger lifting, which can also satisfy the tap
    // recognizer. Ignore taps that immediately follow a drag.
    if (self.lastDragEnd > 0 && CACurrentMediaTime() - self.lastDragEnd < 0.35) return;
    sbk_statusback_PostTrigger();
}

- (void)sbk_statusback_handlePan:(UIPanGestureRecognizer *)gesture {
    UIWindow *window = (UIWindow *)self.superview;
    if (![window isKindOfClass:[UIWindow class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragging = YES;
            self.dragStartCenter = self.center;
            [UIView animateWithDuration:0.1 animations:^{
                self.transform = CGAffineTransformMakeScale(1.15, 1.15);
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [gesture translationInView:window];
            self.center = CGPointMake(self.dragStartCenter.x + translation.x,
                                      self.dragStartCenter.y + translation.y);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            self.dragging = NO;
            self.lastDragEnd = CACurrentMediaTime();
            [UIView animateWithDuration:0.15 animations:^{
                self.transform = CGAffineTransformIdentity;
            }];
            [self sbk_statusback_clampToScreen];
            [[SBKStatusbackConfig sbk_statusback_shared]
                sbk_statusback_setFloatButtonPosition:self.frame.origin];
            break;
        }
        default:
            break;
    }
}

- (void)sbk_statusback_clampToScreen {
    UIWindow *window = (UIWindow *)self.superview;
    if (!window) return;
    CGRect bounds = window.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGPoint center = self.center;
    center.x = MAX(width / 2.0, MIN(bounds.size.width - width / 2.0, center.x));
    center.y = MAX(height / 2.0, MIN(bounds.size.height - height / 2.0, center.y));
    self.center = center;
}

@end

static UIWindow * sbk_statusback_ButtonWindow(void) {
    UIWindowScene *scene = sbk_statusback_HostScene();
    if (!scene) return nil;
    UIWindow *window = objc_getAssociatedObject(scene, (__bridge const void *)kSBKStatusbackWindowKey);
    if ([window isKindOfClass:[UIWindow class]] && !window.hidden) return window;
    return nil;
}

static void sbk_statusback_ShowButton(void) {
    SBKStatusbackConfig *config = [SBKStatusbackConfig sbk_statusback_shared];
    if (![config sbk_statusback_isEnabled]) return;
    if (![config sbk_statusback_showFloatButton]) return;
    if (sbk_statusback_ButtonWindow()) return;

    UIWindowScene *scene = sbk_statusback_HostScene();
    if (!scene) return;

    CGRect bounds = scene.coordinateSpace.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    CGFloat size = [config sbk_statusback_floatButtonSize];
    CGPoint stored = [config sbk_statusback_floatButtonPosition];
    if (stored.x < 0 || stored.y < 0) {
        // Default: right edge, a third of the way down.
        stored = CGPointMake(bounds.size.width - size - 12.0, bounds.size.height * 0.35);
    }
    stored.x = MAX(size / 2.0, MIN(bounds.size.width - size / 2.0, stored.x));
    stored.y = MAX(size / 2.0, MIN(bounds.size.height - size / 2.0, stored.y));

    SBKStatusbackButtonWindow *window =
        [[SBKStatusbackButtonWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 10;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.frame = bounds;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.frame = bounds;
    controller.view.backgroundColor = [UIColor clearColor];
    // The container must stay interaction-enabled: disabling it would
    // recursively disable the button. The window's hitTest: is what makes
    // everything outside the button pass through.
    window.rootViewController = controller;

    SBKStatusbackButtonView *button =
        [[SBKStatusbackButtonView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    button.center = stored;
    button.alpha = [config sbk_statusback_floatButtonAlpha];
    [controller.view addSubview:button];
    objc_setAssociatedObject(window, kSBKStatusbackButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [window makeKeyAndVisible];
    window.hidden = NO;

    objc_setAssociatedObject(scene, (__bridge const void *)kSBKStatusbackWindowKey, window,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void sbk_statusback_HideButton(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *window = objc_getAssociatedObject(scene, (__bridge const void *)kSBKStatusbackWindowKey);
        if ([window isKindOfClass:[UIWindow class]]) {
            window.hidden = YES;
            objc_setAssociatedObject(scene, (__bridge const void *)kSBKStatusbackWindowKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
    }
}

static void sbk_statusback_RelayoutButton(void) {
    UIWindow *window = sbk_statusback_ButtonWindow();
    if (!window) return;
    UIView *button = objc_getAssociatedObject(window, kSBKStatusbackButtonKey);
    if (![button isKindOfClass:[UIView class]]) return;

    SBKStatusbackConfig *config = [SBKStatusbackConfig sbk_statusback_shared];
    button.alpha = [config sbk_statusback_floatButtonAlpha];
    CGFloat size = [config sbk_statusback_floatButtonSize];
    button.bounds = CGRectMake(0, 0, size, size);
    button.layer.cornerRadius = size / 2.0;
    for (UIView *subview in button.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            ((UILabel *)subview).font = [UIFont boldSystemFontOfSize:size * 0.55];
        }
    }
}

static void sbk_statusback_RefreshButton(void) {
    SBKStatusbackConfig *config = [SBKStatusbackConfig sbk_statusback_shared];
    BOOL wanted = [config sbk_statusback_isEnabled] && [config sbk_statusback_showFloatButton];
    UIWindow *existing = sbk_statusback_ButtonWindow();
    if (!wanted) {
        if (existing) sbk_statusback_HideButton();
        return;
    }
    if (existing) {
        sbk_statusback_RelayoutButton();
    } else {
        sbk_statusback_ShowButton();
    }
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

- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ sbk_statusback_RefreshButton(); });
}

- (void)applicationWillResignActive:(UIApplication *)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ sbk_statusback_HideButton(); });
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ sbk_statusback_HideButton(); });
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

static void sbk_statusback_HandlePreferencesChanged(CFNotificationCenterRef center,
                                                    void *observer, CFStringRef name,
                                                    const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sbk_statusback_RefreshButton();
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
    // Rebuild the button whenever preferences change.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, (CFNotificationCallback)sbk_statusback_HandlePreferencesChanged,
        (__bridge CFStringRef)SBKStatusbackPreferencesChanged, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_async(dispatch_get_main_queue(), ^{
        sbk_statusback_ShowButton();
    });
}
