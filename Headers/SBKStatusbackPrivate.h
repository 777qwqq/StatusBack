#pragma once

#import <UIKit/UIKit.h>

// Walk the presented/child tree and return the deepest navigation controller
// that still has something to pop.
@interface UIViewController (SBKStatusbackNavigation)
- (UINavigationController *)sbk_statusback_deepestNavigationController;
@end

// Returns YES when `cls` (or one of its subclasses in the receiving object's
// class hierarchy) implements `selector` itself, rather than inheriting the
// bare UIViewController implementation.
BOOL sbk_statusback_OverridesSelector(Class cls, SEL selector);
