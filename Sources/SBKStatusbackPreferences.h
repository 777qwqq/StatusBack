#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "SBKStatusbackPaths.h"

static NSString * const SBKStatusbackPreferencesDomain = @"com.catpaw.statusback";
static NSString * const SBKStatusbackPreferencesChanged = @"com.catpaw.statusback.preferences-changed";

static inline NSDictionary *sbk_statusback_readPreferences(void) {
    NSString *path = sbk_statusback_preferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    // Compatibility fallback, not a second writable file location.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:SBKStatusbackPreferencesDomain];
    [defaults synchronize];
    return [defaults persistentDomainForName:SBKStatusbackPreferencesDomain] ?: @{};
}

// The PreferenceBundle is the only caller allowed to write.
static inline BOOL sbk_statusback_writePreference(NSString *key, id value, NSError **error) {
    NSString *path = sbk_statusback_preferencesPath();
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:SBKStatusbackPreferencesDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference path or key"}];
        }
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *values;
    if ([manager fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
        id decoded = existing ? [NSPropertyListSerialization propertyListWithData:existing
                         options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:SBKStatusbackPreferencesDomain code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Preferences are not a dictionary"}];
            }
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [sbk_statusback_readPreferences() mutableCopy];
    }
    if (value) values[key] = value;
    else [values removeObjectForKey:key];
    if (![manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:values
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:SBKStatusbackPreferencesDomain];
    // Mirror the whole snapshot so cfprefsd cannot flush stale unrelated keys.
    [defaults setPersistentDomain:values forName:SBKStatusbackPreferencesDomain];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)SBKStatusbackPreferencesChanged, NULL, NULL, true);
    return YES;
}
