#import "SBKStatusbackRootListController.h"
#import "SBKStatusbackPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

@interface SBKStatusbackRootListController ()
@end

@implementation SBKStatusbackRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"SBKStatusbackRoot" target:self] mutableCopy];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return nil;
    return sbk_statusback_readPreferences()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    NSError *error = nil;
    if (!sbk_statusback_writePreference(key, value, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
            message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadSpecifiers];
    }
}

- (void)sbk_statusback_openURL:(NSURL *)url fallback:(NSURL *)fallback {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        if (fallback) {
            [self sbk_statusback_openURL:fallback fallback:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开链接"
                message:@"请确认已安装对应应用。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)sbk_statusback_openRepository:(id)sender {
    NSString *source = @"https://github.com/777qwqq/StatusBack";
    // Encode the entire URL as a path component, including its own delimiters.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *primary = [NSURL URLWithString:[@"sileo://source/" stringByAppendingString:encoded]];
    [self sbk_statusback_openURL:primary fallback:[NSURL URLWithString:source]];
}

- (void)sbk_statusback_openTelegram:(id)sender {
    [self sbk_statusback_openURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
             fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}

- (void)sbk_statusback_openQQ:(id)sender {
    [self sbk_statusback_openURL:[NSURL URLWithString:@"mqqapi://card/show_pslcard?src_type=internal&version=1&uin=678055716&card_type=group&source=qrcode"] fallback:nil];
}

@end
