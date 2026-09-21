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

@interface ISRootListController : PLLocalizedListController
@end

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
