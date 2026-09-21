// IslandSwipe:讓所有動態島(System Aperture)元件都能向左滑隱藏。
//
// iOS 16.5.1 反組譯出的判斷鏈(SpringBoard / SystemApertureUI):
//   -[SBSystemApertureViewController _handleResizeResult:withContainerView:] 在滑動結束時
//   先問 _isInteractiveHidingSupportedByElement: 決定能縮到哪一層 layout mode;到最小層之後
//   再問 layout overrider 的 isInteractiveDismissalEnabled,回 YES 才把 element assertion
//   invalidateWithReason:(這就是「隱藏」)。
//   _isInteractiveHidingSupportedByElement: 對代表狀態列 style override 的元件(螢幕錄影、
//   熱點、通話、定位)一律回 NO;SBSystemApertureSceneElement 則看 Live Activity 自己宣告的
//   SBUISA_preventsInteractiveDismissal。這裡把這幾個閘門全部打開。

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *const kISPrefsDomain = @"com.c3x14n.islandswipe";
static NSString *const kISReloadNotification = @"com.c3x14n.islandswipe/ReloadPrefs";

static BOOL gEnabled = YES;

static void ISLoadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("enabled"), (__bridge CFStringRef)kISPrefsDomain);
    gEnabled = value ? [(__bridge id)value boolValue] : YES;
    if (value) CFRelease(value);
}

static void ISPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ISLoadPrefs();
}

%group SpringBoardHooks

%hook SBSystemApertureViewController
// 狀態列 pill(錄影 / 熱點 / 通話 / 定位)在這裡被擋下。
- (BOOL)_isInteractiveHidingSupportedByElement:(id)element {
    return gEnabled ? YES : %orig;
}
%end

%hook SBSystemApertureSceneElement
// Live Activity 透過 scene client settings 的 SBUISA_preventsInteractiveDismissal 選擇退出。
- (BOOL)isInteractiveDismissalEnabled {
    return gEnabled ? YES : %orig;
}
%end

%end

%group SystemApertureUIHooks

%hook SAUILayoutSpecifyingOverrider
// _handleResizeResult:withContainerView: 最後真正的閘門。
- (BOOL)isInteractiveDismissalEnabled {
    return gEnabled ? YES : %orig;
}
%end

%hook SAUILayoutSpecifyingElementViewController
- (BOOL)isInteractiveDismissalEnabled {
    return gEnabled ? YES : %orig;
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
        if (overrider && elementVC) {
            %init(SystemApertureUIHooks,
                  SAUILayoutSpecifyingOverrider = overrider,
                  SAUILayoutSpecifyingElementViewController = elementVC);
        } else {
            NSLog(@"[IslandSwipe] SystemApertureUI classes not found; only SpringBoard hooks are active");
        }
    }
}
