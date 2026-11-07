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
//
// The .xm source is compiled as Objective-C++, the .m source as Objective-C;
// extern "C" keeps the symbol unmangled so both translation units link.
#ifdef __cplusplus
extern "C" {
#endif
BOOL sbk_statusback_OverridesSelector(Class cls, SEL selector);
#ifdef __cplusplus
}
#endif
