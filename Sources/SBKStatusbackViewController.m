#import "SBKStatusbackPrivate.h"
#import <objc/runtime.h>

BOOL sbk_statusback_OverridesSelector(Class cls, SEL selector) {
    if (!cls || !selector) return NO;
    Class probe = cls;
    while (probe && probe != [NSObject class]) {
        unsigned count = 0;
        Method *methods = class_copyMethodList(probe, &count);
        for (unsigned i = 0; i < count; i++) {
            if (method_getName(methods[i]) == selector) {
                free(methods);
                return YES;
            }
        }
        free(methods);
        probe = class_getSuperclass(probe);
    }
    return NO;
}

@implementation UIViewController (SBKStatusbackNavigation)

- (UINavigationController *)sbk_statusback_deepestNavigationController {
    if ([self isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)self;
        if (nav.viewControllers.count > 1) return nav;
    }

    // Prefer the presented chain, then the selected tab, then children.
    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];
    if (self.presentedViewController) {
        [candidates addObject:self.presentedViewController];
    }
    if (!self.presentingViewController && [self isKindOfClass:[UITabBarController class]]) {
        [candidates addObject:[(UITabBarController *)self selectedViewController]];
    }
    if (!self.presentingViewController) {
        [candidates addObjectsFromArray:self.childViewControllers];
    }

    for (UIViewController *child in candidates) {
        UINavigationController *found = [child sbk_statusback_deepestNavigationController];
        if (found) return found;
    }
    return nil;
}

@end
