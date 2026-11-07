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

- (SBKStatusbackTriggerSide)sbk_statusback_triggerSide {
    return (SBKStatusbackTriggerSide)sbk_statusback_integerValue(self.snapshot, @"triggerSide", SBKStatusbackTriggerSideLeft);
}

- (SBKStatusbackFallbackBehavior)sbk_statusback_fallbackBehavior {
    return (SBKStatusbackFallbackBehavior)sbk_statusback_integerValue(self.snapshot, @"fallbackBehavior", SBKStatusbackFallbackBehaviorHome);
}

- (BOOL)sbk_statusback_showStatusIcon {
    id value = self.snapshot[@"showStatusIcon"];
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    return [value boolValue];
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
