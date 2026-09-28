//
//  ISAutoHideListController.m
//  「自動隱藏」子頁:列出 tweak 記錄過的動態島元件(com.c3x14n.islandswipe.seen.plist),
//  每個一個開關,勾起來的元件一出現就自動收起(往右滑仍叫得回來)。
//  規則存在 com.c3x14n.islandswipe 的 autoHide 字典(key → bool),改了就送 ReloadPrefs 通知。
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <libprefs/prefs.h>

static NSString *const kISDomain = @"com.c3x14n.islandswipe";
static NSString *const kISReload = @"com.c3x14n.islandswipe/ReloadPrefs";
static NSString *const kISSeenPath = @"/var/mobile/Library/Preferences/com.c3x14n.islandswipe.seen.plist";

@interface ISAutoHideListController : PLLocalizedListController
@end

@implementation ISAutoHideListController

- (NSString *)isLocalized:(NSString *)key {
    return [self.bundle localizedStringForKey:key value:key table:nil] ?: key;
}

- (NSMutableArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:nil];
    [header setProperty:[self isLocalized:@"Elements appear here after they have shown in the Dynamic Island at least once. Enabled ones are hidden as soon as they appear; swipe right on the empty island to bring one back."] forKey:@"footerText"];
    [specifiers addObject:header];

    NSDictionary *seen = [NSDictionary dictionaryWithContentsOfFile:kISSeenPath];
    NSArray *keys = [seen.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *na = seen[a][@"name"] ?: a, *nb = seen[b][@"name"] ?: b;
        return [na localizedCaseInsensitiveCompare:nb];
    }];
    for (NSString *key in keys) {
        NSDictionary *entry = seen[key];
        NSString *name = [self displayNameForKey:key entry:entry];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
                                                          target:self
                                                             set:@selector(setAutoHide:specifier:)
                                                             get:@selector(autoHide:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
        [row setProperty:key forKey:@"ruleKey"];
        [row setProperty:@YES forKey:@"enabled"];
        [specifiers addObject:row];
    }
    if (keys.count == 0) {
        PSSpecifier *empty = [PSSpecifier groupSpecifierWithName:nil];
        [empty setProperty:[self isLocalized:@"Nothing recorded yet."] forKey:@"footerText"];
        [specifiers addObject:empty];
    }

    PSSpecifier *clearGroup = [PSSpecifier groupSpecifierWithName:nil];
    [specifiers addObject:clearGroup];
    PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:[self isLocalized:@"Clear recorded elements"]
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                          cell:PSButtonCell
                                                          edit:nil];
    clear->action = @selector(clearSeen:);
    [specifiers addObject:clear];

    _specifiers = specifiers;
    return _specifiers;
}

// 已知的系統元件給翻譯過的名字;其他用 tweak 記到的名稱(App 名稱 / 無障礙標籤)。
- (NSString *)displayNameForKey:(NSString *)key entry:(NSDictionary *)entry {
    static NSDictionary *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = @{
            @"systemApertureElementIdentifierLock": @"Lock",
            @"systemApertureElementIdentifierScreenRecording": @"Screen recording",
            @"SBChargingSystemApertureElementProvider": @"Charging",
            @"systemApertureElementIdentifierHotspot": @"Personal Hotspot",
        };
    });
    NSString *element = [entry[@"element"] isKindOfClass:NSString.class] ? entry[@"element"] : key;
    NSString *knownName = known[key] ?: known[element];
    // 狀態列 pill 的識別字長這樣:"SBSystemApertureStatusBarPillElement - tethering"
    NSString *pillPrefix = @"SBSystemApertureStatusBarPillElement - ";
    if (!knownName && [element hasPrefix:pillPrefix]) {
        NSString *kind = [element substringFromIndex:pillPrefix.length];
        NSDictionary *pills = @{ @"tethering": @"Personal Hotspot", @"recording": @"Screen recording",
                                 @"location": @"Location", @"call": @"Phone call", @"audio": @"Microphone",
                                 @"camera": @"Camera", @"navigation": @"Navigation" };
        knownName = pills[kind] ?: kind.capitalizedString;
    }
    if (knownName) return [self isLocalized:knownName];
    NSString *recorded = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : nil;
    if (recorded.length && ![recorded isEqualToString:key] && ![recorded isEqualToString:@"com.apple.springboard"]) return recorded;
    // 去掉常見前綴讓識別字好讀一點
    NSString *stripped = [element stringByReplacingOccurrencesOfString:@"systemApertureElementIdentifier" withString:@""];
    stripped = [stripped stringByReplacingOccurrencesOfString:@"SystemApertureElementProvider" withString:@""];
    return stripped.length ? stripped : key;
}

- (NSDictionary *)rules {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("autoHide"), (__bridge CFStringRef)kISDomain);
    NSDictionary *rules = [(__bridge id)value isKindOfClass:NSDictionary.class] ? (__bridge NSDictionary *)value : @{};
    if (value) CFRelease(value);
    return rules;
}

- (id)autoHide:(PSSpecifier *)specifier {
    id on = [self rules][[specifier propertyForKey:@"ruleKey"]];
    return @([on respondsToSelector:@selector(boolValue)] && [on boolValue]);
}

- (void)setAutoHide:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *rules = [[self rules] mutableCopy];
    rules[[specifier propertyForKey:@"ruleKey"]] = @([value boolValue]);
    CFPreferencesSetAppValue(CFSTR("autoHide"), (__bridge CFPropertyListRef)rules, (__bridge CFStringRef)kISDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kISDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kISReload, NULL, NULL, true);
}

- (void)clearSeen:(PSSpecifier *)specifier {
    [NSFileManager.defaultManager removeItemAtPath:kISSeenPath error:nil];
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
