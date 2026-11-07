// StatusBack — universal "back" for iOS 16 rootless.
//
// A draggable floating button is shown over the foreground app. Tapping it
// posts a Darwin notification; the foreground app performs one back step.
// When nothing is left to pop, the tweak asks SpringBoard to go home.
//
// The back step is applied to the app's real windows, never to the button
// overlay. The overlay is excluded at two levels: the window lookup skips it
// by class, and the presented-window search treats a presented overlay as
// "no presenter" so it cannot shadow the app's own presented view controller.

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

#pragma mark - Shared helpers

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

// The scene that should host the floating button.
//
// During launch the scene can still be foregroundInactive even though the
// app is about to become active, so a scene that is merely connected is
// accepted as a last resort. Without that fallback the button never appears
// in apps that were cold-launched.
static UIWindowScene * sbk_statusback_HostScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    UIWindowScene *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (scene.activationState == UISceneActivationStateForegroundInactive && !fallback) {
            fallback = windowScene;
        }
    }
    if (fallback) return fallback;

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

// The button's superview is the root view controller's view, not the window.
// Walk up to the real window for coordinate conversion and bounds checks.
- (UIWindow *)sbk_statusback_hostWindow {
    UIResponder *responder = self.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:[UIWindow class]]) return (UIWindow *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

- (void)sbk_statusback_handlePan:(UIPanGestureRecognizer *)gesture {
    UIWindow *window = [self sbk_statusback_hostWindow];
    if (!window) return;

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
    UIWindow *window = [self sbk_statusback_hostWindow];
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

// One overlay per process. A per-scene registry allowed a second overlay to
// be created when the scene enumeration order changed between calls, which
// showed up as two buttons in apps that own several scenes.
static UIWindow *sbk_statusback_gButtonWindow = nil;

static UIWindow * sbk_statusback_ButtonWindow(void) {
    if ([sbk_statusback_gButtonWindow isKindOfClass:[UIWindow class]] &&
        !sbk_statusback_gButtonWindow.hidden) {
        return sbk_statusback_gButtonWindow;
    }
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

    // makeKeyAndVisible is required so the window participates in hit testing;
    // it does not steal touches because hitTest: returns nil outside the
    // button.
    [window makeKeyAndVisible];
    window.hidden = NO;

    sbk_statusback_gButtonWindow = window;
}

// Tears the overlay down instead of only hiding it. A hidden UIWindow stays in
// the window list and keeps its windowLevel; leaving it there means a later
// scene can end up with a second overlay on top of the first.
static void sbk_statusback_HideButton(void) {
    UIWindow *window = sbk_statusback_gButtonWindow;
    sbk_statusback_gButtonWindow = nil;
    if (![window isKindOfClass:[UIWindow class]]) return;

    window.hidden = YES;
    window.rootViewController = nil;
    for (UIView *subview in [window.subviews copy]) {
        [subview removeFromSuperview];
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

// Returns YES when a view controller presented the button overlay. Such a
// window must not be mistaken for a presented view controller by the search
// below, otherwise the overlay shadows whatever the app itself presented.
static BOOL sbk_statusback_PresentsButtonOverlay(UIViewController *controller) {
    if (!controller) return NO;
    UIView *view = controller.view;
    if (!view) return NO;
    UIResponder *responder = view.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:[UIWindow class]]) {
            return [responder isKindOfClass:NSClassFromString(@"SBKStatusbackButtonWindow")];
        }
        responder = responder.nextResponder;
    }
    return NO;
}

// Walks the presented chain from a root, returning every controller that
// could be a back-step target. Controllers already in the skip set are
// omitted, and a presented controller that owns the button overlay is treated
// as the end of the chain.
static NSArray<UIViewController *> * sbk_statusback_SceneCandidates(UIViewController *root,
                                                                   NSMutableSet<UIViewController *> *seen) {
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    UIViewController *controller = root;
    while (controller && ![seen containsObject:controller]) {
        [seen addObject:controller];
        [result addObject:controller];
        UIViewController *presented = controller.presentedViewController;
        if (!presented) break;
        if (sbk_statusback_PresentsButtonOverlay(presented)) break;
        controller = presented;
    }
    return result;
}

// The view controller a back step should act on. Rather than trusting
// keyWindow — which the overlay itself becomes, and which several apps share
// across windows — collect the candidate roots from every app window and pick
// the one that can actually perform a back step.
static UIViewController * sbk_statusback_TargetViewController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    NSMutableSet<UIViewController *> *seen = [NSMutableSet set];

    // Prefer normal-level, visible windows: that is where app content lives.
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if ([window isKindOfClass:NSClassFromString(@"SBKStatusbackButtonWindow")]) continue;
            if (window.hidden) continue;
            if (window.windowLevel != UIWindowLevelNormal) continue;
            NSArray<UIViewController *> *candidates =
                sbk_statusback_SceneCandidates(window.rootViewController, seen);
            if (candidates.count > 0) return candidates.firstObject;
        }
    }

    // Fall back to any remaining visible window, including non-normal levels.
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            if ([window isKindOfClass:NSClassFromString(@"SBKStatusbackButtonWindow")]) continue;
            if (window.hidden) continue;
            NSArray<UIViewController *> *candidates =
                sbk_statusback_SceneCandidates(window.rootViewController, seen);
            if (candidates.count > 0) return candidates.firstObject;
        }
    }
    return nil;
}

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

    // 3) Dismiss a presented view controller. Skip our own overlay, which is
    //    a window rather than a presented controller.
    if (controller.presentedViewController &&
        !sbk_statusback_PresentsButtonOverlay(controller.presentedViewController)) {
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

// Records the navigation controllers actually used by the app. Several apps
// (WeChat, QQ among them) keep their stack in a controller that is not
// reachable from any window's rootViewController, so window-walking alone
// finds nothing to pop.
static NSMutableSet<UINavigationController *> *sbk_statusback_gNavigationControllers = nil;

%hook UINavigationController

- (instancetype)initWithRootViewController:(UIViewController *)rootViewController {
    UINavigationController *result = %orig;
    if (result) {
        if (!sbk_statusback_gNavigationControllers) {
            sbk_statusback_gNavigationControllers = [NSMutableSet set];
        }
        [sbk_statusback_gNavigationControllers addObject:result];
    }
    return result;
}

%end

// The foreground/background transitions are observed through notifications.
// Hooking UIApplication's applicationDidBecomeActive: does nothing: that
// selector belongs to UIApplicationDelegate and is never implemented by
// UIApplication itself, so the hook never fires.

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
                                                    const void *object,
                                                    CFDictionaryRef info) {
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

        UIViewController *controller = sbk_statusback_TargetViewController();
        if (!controller) {
            if ([config sbk_statusback_fallbackBehavior] == SBKStatusbackFallbackBehaviorHome) sbk_statusback_PostHome();
            return;
        }
        if (sbk_statusback_PerformBackOnViewController(controller)) return;

        // The first candidate may be a container with nothing to pop while a
        // deeper window or presented controller does. Walk the whole candidate
        // list before giving up and going home.
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableSet<UIViewController *> *seen = [NSMutableSet set];
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                if ([window isKindOfClass:NSClassFromString(@"SBKStatusbackButtonWindow")]) continue;
                if (window.hidden) continue;
                for (UIViewController *candidate in sbk_statusback_SceneCandidates(window.rootViewController, seen)) {
                    if (sbk_statusback_PerformBackOnViewController(candidate)) return;
                }
            }
        }

        // Last resort: navigation controllers the app created but did not
        // attach to any window's root chain. Prefer the one whose top
        // controller is still on screen.
        for (UINavigationController *nav in [sbk_statusback_gNavigationControllers copy]) {
            if (nav.viewControllers.count <= 1) continue;
            UIViewController *top = nav.topViewController;
            if (top && [top isViewLoaded] && top.view.window) {
                [nav popViewControllerAnimated:YES];
                return;
            }
        }
        for (UINavigationController *nav in [sbk_statusback_gNavigationControllers copy]) {
            if (nav.viewControllers.count <= 1) continue;
            [nav popViewControllerAnimated:YES];
            return;
        }

        if ([config sbk_statusback_fallbackBehavior] == SBKStatusbackFallbackBehaviorHome) sbk_statusback_PostHome();
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, (CFNotificationCallback)sbk_statusback_HandleTriggerCallback,
        (__bridge CFStringRef)SBKStatusbackTriggerNotification, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, (CFNotificationCallback)sbk_statusback_HandlePreferencesChanged,
        (__bridge CFStringRef)SBKStatusbackPreferencesChanged, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // The scene may not be foreground-active yet when the library loads, so
    // retry a few times after launch instead of giving up on the first miss.
    dispatch_async(dispatch_get_main_queue(), ^{
        sbk_statusback_ShowButton();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ sbk_statusback_ShowButton(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ sbk_statusback_ShowButton(); });
    });

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { sbk_statusback_RefreshButton(); }];
    [center addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { sbk_statusback_HideButton(); }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { sbk_statusback_HideButton(); }];
}
