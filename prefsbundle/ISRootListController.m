//
//  ISRootListController.m
//  設定頁的 controller。libprefs 的 PLLocalizedListController 負責從 PreferenceLoader
//  entry 旁邊的 plist(prefs/IslandSwipe.plist)載入項目並翻譯;這個子類只加右上角的
//  「套用」按鈕:確認後透過 FrontBoardServices 的 SBSRelaunchAction 重啟 SpringBoard
//  (Cephei 的做法,不需要 spawn 任何程序)。
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <libprefs/prefs.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <Preferences/PSSpecifier.h>

#ifndef IS_VERSION
#error IS_VERSION comes from PACKAGE_VERSION in the Makefile
#endif

@interface ISRootListController : PLLocalizedListController
@end

#pragma mark - Icons(和 NowLyrics 同一套:列上寫 iconSymbol / iconColor,執行期畫成 SF Symbol 圖示)

static const CGFloat kISIconSize = 29;
static const CGFloat kISIconCornerRadius = 6.5;
static const CGFloat kISIconGlyphPointSize = 15;

static UIColor *ISColorFromHex(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *digits = [value hasPrefix:@"#"] ? [value substringFromIndex:1] : value;
    unsigned rgb = 0;
    if (digits.length != 6 || ![[NSScanner scannerWithString:digits] scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

static UIImage *ISTileIcon(NSString *symbolName, UIColor *color) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kISIconGlyphPointSize weight:UIImageSymbolWeightMedium];
    UIImage *glyph = [[UIImage systemImageNamed:symbolName withConfiguration:configuration]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGRect tile = CGRectMake(0, 0, kISIconSize, kISIconSize);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:tile.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:kISIconCornerRadius] fill];
        if (!glyph) return;
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((kISIconSize - size.width) / 2, (kISIconSize - size.height) / 2, size.width, size.height)];
    }];
}

static void ISApplyIcon(PSSpecifier *specifier) {
    if ([specifier propertyForKey:PSIconImageKey]) return;
    NSString *symbol = [specifier propertyForKey:@"iconSymbol"];
    UIColor *color = ISColorFromHex([specifier propertyForKey:@"iconColor"]);
    if (![symbol isKindOfClass:[NSString class]] || !color) return;
    [specifier setProperty:ISTileIcon(symbol, color) forKey:PSIconImageKey];
}

// 字串放在 PreferenceLoader 的 prefs 資料夾(和 plist 同一份 Localizable.strings)。
static NSString *ISLocalized(NSString *key) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *root in @[@"/var/jb", @""]) {
            NSBundle *candidate = [NSBundle bundleWithPath:[root stringByAppendingString:@"/Library/PreferenceLoader/Preferences/IslandSwipe"]];
            if (candidate) { bundle = candidate; break; }
        }
    });
    return [bundle localizedStringForKey:key value:key table:nil] ?: key;
}

@implementation ISRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:ISLocalized(@"Apply")
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(isApplyTapped)];
}

- (NSMutableArray *)specifiers {
    NSMutableArray *specifiers = [super specifiers];
    for (PSSpecifier *specifier in specifiers) ISApplyIcon(specifier);
    return specifiers;
}

// 「關於」的版本列(plist 的 get = isVersion:)。
- (NSString *)isVersion:(PSSpecifier *)specifier {
    return @IS_VERSION;
}

- (void)isApplyTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ISLocalized(@"Apply")
                                                                   message:ISLocalized(@"Restart SpringBoard to apply?")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ISLocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ISLocalized(@"Respring") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self isRespring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)isRespring {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    Class actionClass = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;
    // SBSRelaunchActionOptionsRestartRenderServer = 1 << 0
    id action = ((id (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(actionClass, @selector(actionWithReason:options:targetURL:), @"IslandSwipe", 1, nil);
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, @selector(sharedService));
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, @selector(sendActions:withResult:), [NSSet setWithObject:action], nil);
}

@end
