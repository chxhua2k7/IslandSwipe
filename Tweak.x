// IslandSwipe:讓所有動態島(System Aperture)元件都能向左滑隱藏,再往右滑叫回來。
//
// iOS 16.5.1 反組譯出的判斷鏈(SpringBoard / SystemApertureUI):
//   -[SBSystemApertureViewController _handleResizeResult:withContainerView:] 在往左滑結束時:
//     floor = _isInteractiveHidingSupportedByElement: ? max(minimumSupportedLayoutMode, 2)
//                                                      : minimumSupportedLayoutMode
//     目前 layoutMode > floor  → overrider setPreferredLayoutMode:(layoutMode-1) reason:3(使用者手勢)
//     已經在 floor            → overrider isInteractiveDismissalEnabled 才把 element assertion 作廢(整個移除)
//   往右滑且無法再放大時,會找 preferredLayoutModeAssertion 是 reason 3、mode 0 的元件,
//   把那個 assertion 作廢("User Unhide")→ 元件重新出現。layout mode 0 = 隱藏但仍註冊。
//   _isInteractiveHidingSupportedByElement: 對代表狀態列 style override 的元件(螢幕錄影、
//   熱點、通話、定位)回 NO;Live Activity 可用 SBUISA_preventsInteractiveDismissal 拒絕移除。
//
// 做法:對「系統本來不准滑掉」的元件不走移除(移除會把 scene element 作廢,叫不回來),
// 而是走系統自己的隱藏:在 _handleResizeResult 期間讓 minimumSupportedLayoutMode 回 0,
// 並把 reason 3 的縮小直接設成 mode 0。復原用系統的 _axRevealHiddenElementIfPossible。
// 動態島空著時它的視窗收不到觸控,所以另開一個只蓋住動態島區域的高層級小視窗接往右滑。

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@protocol ISElementDismissal <NSObject>
- (BOOL)isInteractiveDismissalEnabled;
@end

@interface SAUIPreferredLayoutModeAssertion : NSObject
@property (readonly, nonatomic) NSInteger layoutModeChangeReason;
@property (readonly, nonatomic) NSInteger preferredLayoutMode;
@property (readonly, nonatomic, getter=isValid) BOOL valid;
@end

@interface SAUILayoutSpecifyingOverrider : NSObject
@property (readonly, weak, nonatomic) id layoutSpecifyingOverridingTarget;
@property (readonly, nonatomic) NSInteger layoutMode;
@property (readonly, nonatomic) SAUIPreferredLayoutModeAssertion *preferredLayoutModeAssertion;
@end

// SystemApertureUI 匯出的 C 函式:元件 → 它的 layout overrider。
static SAUILayoutSpecifyingOverrider *(*ISOverriderForElement)(id element);

@interface SBSystemApertureViewController : UIViewController
@property (readonly, nonatomic) CGRect minimumSensorRegionFrame;
- (void)_axRevealHiddenElementIfPossible;
@end

@interface SBSystemApertureContainerView : UIView
@end

@interface SBAccessoryWindowScene : UIWindowScene
@property (nonatomic) UIWindowScene *associatedWindowScene;
@end

static NSString *const kISPrefsDomain = @"com.c3x14n.islandswipe";
static NSString *const kISReloadNotification = @"com.c3x14n.islandswipe/ReloadPrefs";

static BOOL gEnabled = YES;
// 空閒時不畫黑色膠囊(只剩硬體的洞)。
static BOOL gHideIdle = YES;
static BOOL gHasContent = YES;
static NSHashTable *gContainerViews;
// 系統原本不准滑掉的元件(弱引用;元件消失就自動掉出)。
static NSHashTable *gForcedElements;
// 被我們設成 mode 0 隱藏、等著叫回來的元件(弱引用)。
static NSHashTable *gHiddenElements;
static BOOL gHandlingResize;
static __weak SBSystemApertureViewController *gApertureVC;
static UIWindow *gUnhideWindow;

static void ISLoadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("enabled"), (__bridge CFStringRef)kISPrefsDomain);
    gEnabled = value ? [(__bridge id)value boolValue] : YES;
    if (value) CFRelease(value);
    CFPropertyListRef idle = CFPreferencesCopyAppValue(CFSTR("hideIdle"), (__bridge CFStringRef)kISPrefsDomain);
    gHideIdle = idle ? [(__bridge id)idle boolValue] : YES;
    if (idle) CFRelease(idle);
}

static CGFloat ISContainerAlpha(void) {
    return (gEnabled && gHideIdle && !gHasContent) ? 0 : 1;
}

static void ISUpdateIdleHiding(BOOL animated) {
    CGFloat alpha = ISContainerAlpha();
    void (^apply)(void) = ^{
        for (UIView *view in gContainerViews.allObjects) view.alpha = alpha;
    };
    if (animated) [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
    else apply();
}

static void ISPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ISLoadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateIdleHiding(YES); });
}

static BOOL ISIsForced(id element) {
    return element && [gForcedElements containsObject:element];
}

static void ISForgetHidden(id element) {
    if (element) [gHiddenElements removeObject:element];
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

static void ISUpdateUnhideWindow(void);

@interface ISUnhideView : UIView
@end
@implementation ISUnhideView
- (void)unhide:(UISwipeGestureRecognizer *)recognizer {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc || gHiddenElements.count == 0) return;
    // 系統自己的「User Unhide」:找 reason 3 / mode 0 的元件,把它的 preferred layout mode assertion 作廢。
    [vc _axRevealHiddenElementIfPossible];
    [vc.view setNeedsLayout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}
@end

// 還在隱藏 = overrider 上仍掛著 reason 3 / mode 0 的 preferred layout mode assertion(系統 User Unhide 找的就是它)。
static BOOL ISIsStillHidden(id element) {
    if (!ISOverriderForElement) return YES;
    SAUILayoutSpecifyingOverrider *overrider = ISOverriderForElement(element);
    SAUIPreferredLayoutModeAssertion *assertion = overrider.preferredLayoutModeAssertion;
    BOOL hidden = assertion && assertion.layoutModeChangeReason == 3 && assertion.preferredLayoutMode == 0
                  && (![assertion respondsToSelector:@selector(isValid)] || assertion.isValid);
    return hidden;
}

static void ISPruneHidden(void) {
    for (id element in gHiddenElements.allObjects) {
        if (!ISIsStillHidden(element)) [gHiddenElements removeObject:element];
    }
}

static void ISUpdateUnhideWindow(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc.isViewLoaded || !vc.view.window) return;
    ISPruneHidden();
    if (gHiddenElements.count == 0 || !gEnabled) {
        gUnhideWindow.hidden = YES;
        gUnhideWindow = nil;
        return;
    }
    UIWindowScene *scene = vc.view.window.windowScene;
    if ([scene respondsToSelector:@selector(associatedWindowScene)]) {
        UIWindowScene *assoc = [(SBAccessoryWindowScene *)scene associatedWindowScene];
        if (assoc) scene = assoc;
    }
    CGRect frame = CGRectInset(vc.minimumSensorRegionFrame, -24, -12);
    frame = [vc.view convertRect:frame toCoordinateSpace:vc.view.window.screen.coordinateSpace];
    if (!gUnhideWindow) {
        gUnhideWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:frame];
        gUnhideWindow.windowLevel = UIWindowLevelStatusBar + 60;
        gUnhideWindow.backgroundColor = UIColor.clearColor;
        ISUnhideView *view = [[ISUnhideView alloc] initWithFrame:CGRectZero];
        view.backgroundColor = UIColor.clearColor;
        view.accessibilityLabel = @"IslandSwipe";
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:view action:@selector(unhide:)];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        [view addGestureRecognizer:swipe];
        UIViewController *root = [UIViewController new];
        root.view = view;
        gUnhideWindow.rootViewController = root;
    }
    if (!CGRectEqualToRect(gUnhideWindow.frame, frame)) gUnhideWindow.frame = frame;
    gUnhideWindow.rootViewController.view.frame = gUnhideWindow.bounds;
    gUnhideWindow.hidden = NO;
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
    ISUpdateUnhideWindow();
}

// 系統本來就允許移除的元件維持原樣;不允許的改走「縮到 mode 0」的隱藏路徑。
- (BOOL)_isInteractiveHidingSupportedByElement:(id)element {
    BOOL orig = %orig;
    if (!gEnabled || !element) return orig;
    BOOL dismissable = ![element respondsToSelector:@selector(isInteractiveDismissalEnabled)]
                       || [(id<ISElementDismissal>)element isInteractiveDismissalEnabled];
    if (orig && dismissable) return orig;
    if (!gForcedElements) gForcedElements = [NSHashTable weakObjectsHashTable];
    [gForcedElements addObject:element];
    return NO;
}

- (void)_handleResizeResult:(NSInteger)result withContainerView:(id)containerView {
    gHandlingResize = gEnabled;
    %orig;
    gHandlingResize = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}

%end

// 動態島有沒有內容:沒有時把 container view(空閒時那圈黑色膠囊)整個淡出。
%hook SBSystemApertureController
- (void)systemApertureViewController:(id)viewController containsAnyContent:(BOOL)containsAnyContent {
    %orig;
    gHasContent = containsAnyContent;
    ISUpdateIdleHiding(YES);
}
%end

%hook SBSystemApertureContainerView
- (void)layoutSubviews {
    %orig;
    if (!gContainerViews) gContainerViews = [NSHashTable weakObjectsHashTable];
    [gContainerViews addObject:self];
    CGFloat alpha = ISContainerAlpha();
    if (self.alpha != alpha) self.alpha = alpha;
}
%end

%hook SBSystemApertureSceneElement
- (void)invalidate {
    ISForgetHidden(self);
    %orig;
}
%end

%hook SBSystemApertureStatusBarPillElementProvider
- (void)_invalidateElement:(id)element withReason:(id)reason {
    ISForgetHidden(element);
    %orig;
}
%end

%end

%group SystemApertureUIHooks

%hook SAUILayoutSpecifyingOverrider

// 處理滑動結果的期間放寬到 0(讓 _handleResizeResult 的 floor 變成 0);
// 已隱藏的元件也一直維持 0,否則系統會把 mode 0 夾回最小值。
- (NSInteger)minimumSupportedLayoutMode {
    NSInteger orig = %orig;
    if (!gEnabled) return orig;
    id element = ISElementForOverrider(self);
    if ((gHandlingResize && ISIsForced(element)) || [gHiddenElements containsObject:element]) return 0;
    return orig;
}

// 使用者往左滑(reason 3)要縮小時,直接縮到 0(隱藏),不用一格一格滑。
- (void)setPreferredLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    id element = ISElementForOverrider(self);
    NSInteger current = [(SAUILayoutSpecifyingOverrider *)self layoutMode];
    if (gHandlingResize && reason == 3 && mode < current && ISIsForced(element)) {
        if (!gHiddenElements) gHiddenElements = [NSHashTable weakObjectsHashTable];
        [gHiddenElements addObject:element];
        %orig(0, reason);
        return;
    }
    %orig;
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

        dlopen("/System/Library/PrivateFrameworks/SystemApertureUI.framework/SystemApertureUI", RTLD_NOW);
        Class overrider = objc_getClass("SAUILayoutSpecifyingOverrider");
        ISOverriderForElement = (SAUILayoutSpecifyingOverrider *(*)(id))dlsym(RTLD_DEFAULT, "SAUILayoutSpecifyingOverriderForElement");
        if (!ISOverriderForElement) NSLog(@"[IslandSwipe] SAUILayoutSpecifyingOverriderForElement not found");
        if (overrider) {
            %init(SystemApertureUIHooks, SAUILayoutSpecifyingOverrider = overrider);
        } else {
            NSLog(@"[IslandSwipe] SystemApertureUI classes not found; only SpringBoard hooks are active");
        }
    }
}
