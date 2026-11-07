#import "SBKStatusbackConfig.h"
#import "SBKStatusbackPreferences.h"

@interface SBKStatusbackConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void sbk_statusback_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef info) {
    SBKStatusbackConfig *config = (__bridge SBKStatusbackConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config sbk_statusback_reload];
    });
}

static NSInteger sbk_statusback_integerValue(NSDictionary *snapshot, NSString *key, NSInteger fallback) {
    id value = snapshot[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    if ([value isKindOfClass:[NSString class]]) return [value integerValue];
    return fallback;
}

static CGFloat sbk_statusback_doubleValue(NSDictionary *snapshot, NSString *key, CGFloat fallback) {
    id value = snapshot[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSString class]]) return [value doubleValue];
    return fallback;
}

@implementation SBKStatusbackConfig

+ (instancetype)sbk_statusback_shared {
    static SBKStatusbackConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.catpaw.statusback.preferences", DISPATCH_QUEUE_SERIAL);
        [self sbk_statusback_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, sbk_statusback_preferencesDidChange,
            (__bridge CFStringRef)SBKStatusbackPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self sbk_statusback_reload]; });
    }
    return self;
}

- (void)sbk_statusback_reload {
    self.snapshot = sbk_statusback_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SBKStatusbackPreferencesChanged object:self];
    });
}

- (BOOL)sbk_statusback_isEnabled {
    id value = self.snapshot[@"enabled"];
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) return [value boolValue];
    return NO;
}

- (SBKStatusbackFallbackBehavior)sbk_statusback_fallbackBehavior {
    return (SBKStatusbackFallbackBehavior)sbk_statusback_integerValue(self.snapshot, @"fallbackBehavior", SBKStatusbackFallbackBehaviorHome);
}

- (BOOL)sbk_statusback_showFloatButton {
    id value = self.snapshot[@"showFloatButton"];
    if (![value isKindOfClass:[NSNumber class]]) return YES;
    return [value boolValue];
}

- (CGFloat)sbk_statusback_floatButtonAlpha {
    CGFloat alpha = sbk_statusback_doubleValue(self.snapshot, @"floatButtonAlpha", 0.85);
    return MAX(0.2, MIN(1.0, alpha));
}

- (CGFloat)sbk_statusback_floatButtonSize {
    CGFloat size = sbk_statusback_doubleValue(self.snapshot, @"floatButtonSize", 48.0);
    return MAX(32.0, MIN(96.0, size));
}

- (CGPoint)sbk_statusback_floatButtonPosition {
    id x = self.snapshot[@"floatButtonX"];
    id y = self.snapshot[@"floatButtonY"];
    if ([x isKindOfClass:[NSNumber class]] && [y isKindOfClass:[NSNumber class]]) {
        return CGPointMake([x doubleValue], [y doubleValue]);
    }
    return CGPointMake(-1.0, -1.0);   // not configured yet
}

- (void)sbk_statusback_setFloatButtonPosition:(CGPoint)position {
    if (!isfinite(position.x) || !isfinite(position.y)) return;
    NSError *error = nil;
    if (!sbk_statusback_writePreference(@"floatButtonX", @(position.x), &error)) return;
    if (!sbk_statusback_writePreference(@"floatButtonY", @(position.y), &error)) return;
    // The snapshot is refreshed by the Darwin notification that the write
    // triggers; no need to touch the cache here.
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
