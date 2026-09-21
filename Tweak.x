// IslandSwipe:讓所有動態島(System Aperture)元件都能向左滑隱藏,再往右滑叫回來。
//
// iOS 16.5.1 反組譯出的判斷鏈(SpringBoard / SystemApertureUI):
//   -[SBSystemApertureViewController _handleResizeResult:withContainerView:] 在滑動結束時
//   先問 _isInteractiveHidingSupportedByElement: 決定能縮到哪一層 layout mode;到最小層之後
//   再問 layout overrider 的 isInteractiveDismissalEnabled,回 YES 才把 element assertion
//   invalidateWithReason:@"removed via pan gesture"(元件整個從動態島移除)。
//   _isInteractiveHidingSupportedByElement: 對代表狀態列 style override 的元件(螢幕錄影、
//   熱點、通話、定位)一律回 NO;SBSystemApertureSceneElement 則看 Live Activity 自己宣告的
//   SBUISA_preventsInteractiveDismissal。這裡把這幾個閘門全部打開。
//
// 復原:被移除的元件不會自己回來(狀態列 pill 的 provider 透過 clientStorage 以為它還註冊著),
// 所以把「原本系統不准滑掉、被我們強制移除」的元件記下來,在空的動態島放一個透明的手勢區,
// 往右滑就用 registerElement: 重新註冊。provider 自己把元件作廢(例如錄影結束)時就從清單移除。

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@interface SAUIElementAssertion : NSObject
@property (readonly, weak, nonatomic) id element;
@end

@interface SAUILayoutSpecifyingOverrider : NSObject
@property (readonly, weak, nonatomic) id layoutSpecifyingOverridingTarget;
@end

@interface SBSystemApertureViewController : UIViewController
@property (readonly, nonatomic) CGRect minimumSensorRegionFrame;
- (id)registerElement:(id)element;
@end

static NSString *const kISPrefsDomain = @"com.c3x14n.islandswipe";
static NSString *const kISReloadNotification = @"com.c3x14n.islandswipe/ReloadPrefs";

static BOOL gEnabled = YES;

// 系統原本不准滑掉的元件(弱引用;元件消失就自動掉出)。
static NSHashTable *gForcedElements;
// 被我們強制移除、等著被叫回來的元件(強引用,順序 = 隱藏順序)。
static NSMutableArray *gHiddenElements;
static __weak SBSystemApertureViewController *gApertureVC;
static UIView *gUnhideView;

static void ISLoadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("enabled"), (__bridge CFStringRef)kISPrefsDomain);
    gEnabled = value ? [(__bridge id)value boolValue] : YES;
    if (value) CFRelease(value);
}

static void ISPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ISLoadPrefs();
}

static void ISMarkForced(id element) {
    if (!element) return;
    if (!gForcedElements) gForcedElements = [NSHashTable weakObjectsHashTable];
    [gForcedElements addObject:element];
}

static void ISForgetHidden(id element) {
    if (!element) return;
    [gHiddenElements removeObjectIdenticalTo:element];
}

// overrider 的 target 是 element view controller(elementViewProvider.element)或元件本身。
static id ISElementForOverrider(SAUILayoutSpecifyingOverrider *overrider) {
    id target = overrider.layoutSpecifyingOverridingTarget;
    if ([target respondsToSelector:@selector(elementViewProvider)]) {
        id provider = [target performSelector:@selector(elementViewProvider)];
        if ([provider respondsToSelector:@selector(element)]) return [provider performSelector:@selector(element)];
        return provider;
    }
    if ([target respondsToSelector:@selector(element)]) return [target performSelector:@selector(element)];
    return target;
}

@interface ISUnhideView : UIView
@end
@implementation ISUnhideView
- (void)unhide:(UISwipeGestureRecognizer *)recognizer {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc || gHiddenElements.count == 0) return;
    // 一次叫回最後一個被隱藏的元件;再滑一次叫下一個。
    id element = gHiddenElements.lastObject;
    [gHiddenElements removeLastObject];
    id assertion = [vc registerElement:element];
    // 狀態列 pill 的 provider 用 clientStorage 記 assertion,換成新的它才能在錄影結束時作廢。
    if (assertion && [element respondsToSelector:@selector(setClientStorage:)]) {
        [element performSelector:@selector(setClientStorage:) withObject:assertion];
    }
    [vc.view setNeedsLayout];
}
@end

static void ISUpdateUnhideView(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc.isViewLoaded) return;
    if (gHiddenElements.count == 0 || !gEnabled) {
        [gUnhideView removeFromSuperview];
        gUnhideView = nil;
        return;
    }
    if (!gUnhideView) {
        gUnhideView = [[ISUnhideView alloc] initWithFrame:CGRectZero];
        gUnhideView.backgroundColor = UIColor.clearColor;
        gUnhideView.accessibilityLabel = @"IslandSwipe";
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:gUnhideView action:@selector(unhide:)];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        [gUnhideView addGestureRecognizer:swipe];
    }
    // 放在最底層,有元件顯示時它們的 container view 先拿到觸控。
    if (gUnhideView.superview != vc.view) [vc.view insertSubview:gUnhideView atIndex:0];
    // 手勢區 = 感測器區域往外放大一點,方便手指抓到。
    gUnhideView.frame = CGRectInset(vc.minimumSensorRegionFrame, -24, -12);
}

%group SpringBoardHooks

%hook SBSystemApertureViewController

- (void)viewDidLoad {
    %orig;
    gApertureVC = self;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!gApertureVC) gApertureVC = self;
    ISUpdateUnhideView();
}

// 狀態列 pill(錄影 / 熱點 / 通話 / 定位)在這裡被擋下。
- (BOOL)_isInteractiveHidingSupportedByElement:(id)element {
    BOOL orig = %orig;
    if (!gEnabled) return orig;
    if (!orig) ISMarkForced(element);
    return YES;
}

%end

%hook SBSystemApertureSceneElement
// Live Activity 透過 scene client settings 的 SBUISA_preventsInteractiveDismissal 選擇退出。
- (BOOL)isInteractiveDismissalEnabled {
    BOOL orig = %orig;
    if (!gEnabled) return orig;
    if (!orig) ISMarkForced(self);
    return YES;
}
- (void)invalidate {
    ISForgetHidden(self);
    %orig;
    ISUpdateUnhideView();
}
%end

%hook SBSystemApertureStatusBarPillElementProvider
// 錄影 / 熱點結束時 provider 自己作廢元件,就不能再叫回來了。
- (void)_invalidateElement:(id)element withReason:(id)reason {
    ISForgetHidden(element);
    %orig;
    ISUpdateUnhideView();
}
%end

%end

%group SystemApertureUIHooks

%hook SAUILayoutSpecifyingOverrider
// _handleResizeResult:withContainerView: 最後真正的閘門。
- (BOOL)isInteractiveDismissalEnabled {
    BOOL orig = %orig;
    if (!gEnabled) return orig;
    if (!orig) ISMarkForced(ISElementForOverrider(self));
    return YES;
}
%end

%hook SAUILayoutSpecifyingElementViewController
- (BOOL)isInteractiveDismissalEnabled {
    return gEnabled ? YES : %orig;
}
%end

%hook SAUIElementAssertion
// 滑掉 = 這個 assertion 被作廢。只記住原本不准滑掉的元件,系統本來就允許的維持原樣。
- (void)invalidateWithReason:(NSString *)reason layoutModeChangeReason:(NSInteger)changeReason {
    id element = [(SAUIElementAssertion *)self element];
    if (gEnabled && element && [reason isKindOfClass:NSString.class] && [reason containsString:@"pan gesture"]
        && [gForcedElements containsObject:element]) {
        if (!gHiddenElements) gHiddenElements = [NSMutableArray array];
        [gHiddenElements removeObjectIdenticalTo:element];
        [gHiddenElements addObject:element];
    }
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateUnhideView(); });
}
%end

%end

%ctor {
    @autoreleasepool {
        ISLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, ISPrefsChanged,
                                        (__bridge CFStringRef)kISReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        %init(SpringBoardHooks);

        // SpringBoard 載入時 SystemApertureUI 可能還沒進來,先手動載入再取 class。
        dlopen("/System/Library/PrivateFrameworks/SystemApertureUI.framework/SystemApertureUI", RTLD_NOW);
        Class overrider = objc_getClass("SAUILayoutSpecifyingOverrider");
        Class elementVC = objc_getClass("SAUILayoutSpecifyingElementViewController");
        Class assertion = objc_getClass("SAUIElementAssertion");
        if (overrider && elementVC && assertion) {
            %init(SystemApertureUIHooks,
                  SAUILayoutSpecifyingOverrider = overrider,
                  SAUILayoutSpecifyingElementViewController = elementVC,
                  SAUIElementAssertion = assertion);
        } else {
            NSLog(@"[IslandSwipe] SystemApertureUI classes not found; only SpringBoard hooks are active");
        }
    }
}
