// IslandSwipe:讓所有動態島(System Aperture)元件都能向左滑隱藏、往右滑叫回來,
// 並可在空閒時不畫感測器外圍的黑色。
//
// 滑動隱藏(iOS 16.5.1 反組譯,SpringBoard / SystemApertureUI):
//   -[SBSystemApertureViewController _handleResizeResult:withContainerView:] 在往左滑結束時:
//     floor = _isInteractiveHidingSupportedByElement: ? max(minimumSupportedLayoutMode, 2)
//                                                      : minimumSupportedLayoutMode
//     目前 layoutMode > floor  → overrider setPreferredLayoutMode:(layoutMode-1) reason:3(使用者手勢)
//     已經在 floor            → overrider isInteractiveDismissalEnabled 才把 element assertion 作廢(整個移除)
//   往右滑且無法再放大時,會找 preferredLayoutModeAssertion 是 reason 3、mode 0 的元件把它作廢
//   ("User Unhide")→ 元件重新出現。layout mode 0 = 隱藏但仍註冊。
//   _isInteractiveHidingSupportedByElement: 對代表狀態列 style override 的元件(螢幕錄影、熱點、
//   通話、定位)回 NO;Live Activity 可用 SBUISA_preventsInteractiveDismissal 拒絕移除。
//   對這些「系統不准滑掉」的元件不走移除(移除會把 scene element 作廢,叫不回來),而是走系統自己的
//   隱藏:在 _handleResizeResult 期間讓 minimumSupportedLayoutMode 回 0,並把 reason 3 的縮小直接
//   設成 mode 0;復原用系統的 _axRevealHiddenElementIfPossible。動態島空著時它的視窗收不到觸控,
//   所以另開一個只蓋住動態島區域的高層級小視窗接往右滑。
//
// 空閒時隱藏(做法沿用 DynamicNotLand,verygenericname,GPL):
//   兩個硬體缺口之間被塗黑的像素是 CAGainMapLayer 畫的,SpringBoard 建立的第一個 _SBGainMapView
//   會變成 backboardd 顯示層級的遮罩(截圖截不到、alpha / hidden 都不理)。啟動時先在主畫面的
//   SBRootSceneWindow 放一個 1x1 的 _SBGainMapView 佔掉這個名額,之後的 _SBGainMapView 都改用
//   普通 CALayer(黑色背景),沒內容時就能用 opacity 淡出。佔位一定要放在 SBRootSceneWindow,放進
//   別的 scene 或被別的 tweak 套 transform / 濾鏡都會讓 backboardd 的 gain encoder 崩潰。

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#pragma mark - 私有介面

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

@interface SBSystemApertureViewController : UIViewController
@property (readonly, nonatomic) CGRect minimumSensorRegionFrame;
- (void)_axRevealHiddenElementIfPossible;
@end

@interface SBSystemApertureContainerView : UIView
@end

@interface _SBGainMapView : UIView
@end

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end

@interface SBAccessoryWindowScene : UIWindowScene
@property (nonatomic) UIWindowScene *associatedWindowScene;
@end

@interface SpringBoard : UIApplication
@end

@interface CALayer (ISUndocumented)
@property (atomic, assign) NSUInteger disableUpdateMask;
@end

// 普通 CALayer 假扮 CAGainMapLayer:SpringBoard 會對它設 renderMode 之類的屬性,吃掉就好。
@interface ISFakeGainMapLayer : CALayer
@property (nonatomic, copy) NSString *renderMode;
@end
@implementation ISFakeGainMapLayer
@end

#pragma mark - 狀態

static NSString *const kISPrefsDomain = @"com.c3x14n.islandswipe";
static NSString *const kISReloadNotification = @"com.c3x14n.islandswipe/ReloadPrefs";

static BOOL gEnabled = YES;
static BOOL gHideIdle = YES;

// SystemApertureUI 匯出的 C 函式:元件 → 它的 layout overrider。
static SAUILayoutSpecifyingOverrider *(*ISOverriderForElement)(id element);
static __weak SBSystemApertureViewController *gApertureVC;

// 滑動隱藏
static NSHashTable *gForcedElements;   // 系統原本不准滑掉的元件(弱引用)
static NSHashTable *gHiddenElements;   // 被設成 mode 0 隱藏、等著叫回來的元件(弱引用)
static BOOL gHandlingResize;
static UIWindow *gUnhideWindow;

// 空閒時隱藏
static BOOL gHasContent = YES;
static BOOL gFirstGainMapLayer;        // 下一個 layerClass 請求給真的 CAGainMapLayer(佔位 view)
static UIView *gPlaceholderView;
static NSHashTable *gGainMapViews;     // 佔位以外的 _SBGainMapView
static NSHashTable *gCurtainViews;
static NSHashTable *gContainerViews;

static void ISLoadPrefs(void) {
    CFPropertyListRef enabled = CFPreferencesCopyAppValue(CFSTR("enabled"), (__bridge CFStringRef)kISPrefsDomain);
    gEnabled = enabled ? [(__bridge id)enabled boolValue] : YES;
    if (enabled) CFRelease(enabled);
    CFPropertyListRef hideIdle = CFPreferencesCopyAppValue(CFSTR("hideIdle"), (__bridge CFStringRef)kISPrefsDomain);
    gHideIdle = hideIdle ? [(__bridge id)hideIdle boolValue] : YES;
    if (hideIdle) CFRelease(hideIdle);
}

static BOOL ISIdleHidden(void) {
    return gEnabled && gHideIdle && !gHasContent;
}

static void ISAddWeak(NSHashTable *__strong *table, id object) {
    if (!*table) *table = [NSHashTable weakObjectsHashTable];
    [*table addObject:object];
}

#pragma mark - 滑動隱藏

// overrider 的 target 是 element view controller(elementViewProvider.element)或元件本身。
static id ISElementForOverrider(SAUILayoutSpecifyingOverrider *overrider) {
    id target = overrider.layoutSpecifyingOverridingTarget;
    if ([target respondsToSelector:@selector(elementViewProvider)]) {
        id provider = [target performSelector:@selector(elementViewProvider)];
        return [provider respondsToSelector:@selector(element)] ? [provider performSelector:@selector(element)] : provider;
    }
    return [target respondsToSelector:@selector(element)] ? [target performSelector:@selector(element)] : target;
}

// 還在隱藏 = overrider 上仍掛著 reason 3 / mode 0 的 preferred layout mode assertion(系統 User Unhide 找的就是它)。
static BOOL ISIsStillHidden(id element) {
    if (!ISOverriderForElement) return YES;
    SAUIPreferredLayoutModeAssertion *assertion = ISOverriderForElement(element).preferredLayoutModeAssertion;
    return assertion && assertion.layoutModeChangeReason == 3 && assertion.preferredLayoutMode == 0
        && (![assertion respondsToSelector:@selector(isValid)] || assertion.isValid);
}

static void ISUpdateUnhideWindow(void);
static void ISUpdateIdleHiding(BOOL animated);

@interface ISUnhideView : UIView
@end
@implementation ISUnhideView
- (void)unhide:(UISwipeGestureRecognizer *)recognizer {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc || gHiddenElements.count == 0) return;
    [vc _axRevealHiddenElementIfPossible];
    [vc.view setNeedsLayout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}
@end

// 有元件被隱藏時,在動態島區域放一個透明的高層級小視窗接往右滑(動態島自己的視窗空著時收不到觸控)。
static void ISUpdateUnhideWindow(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc.isViewLoaded || !vc.view.window) return;
    for (id element in gHiddenElements.allObjects) {
        if (!ISIsStillHidden(element)) [gHiddenElements removeObject:element];
    }
    // 只在動態島空著時放手勢視窗;有內容顯示時它會擋住元件的點擊(點了不會開 App)。
    if (gHiddenElements.count == 0 || !gEnabled || gHasContent) {
        gUnhideWindow.hidden = YES;
        gUnhideWindow = nil;
        return;
    }
    UIWindowScene *scene = vc.view.window.windowScene;
    if ([scene respondsToSelector:@selector(associatedWindowScene)]) {
        scene = [(SBAccessoryWindowScene *)scene associatedWindowScene] ?: scene;
    }
    CGRect frame = [vc.view convertRect:CGRectInset(vc.minimumSensorRegionFrame, -24, -12)
                      toCoordinateSpace:vc.view.window.screen.coordinateSpace];
    if (!gUnhideWindow) {
        gUnhideWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:frame];
        gUnhideWindow.windowLevel = UIWindowLevelStatusBar + 60;
        gUnhideWindow.backgroundColor = UIColor.clearColor;
        ISUnhideView *view = [[ISUnhideView alloc] initWithFrame:CGRectZero];
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

%group SwipeHooks

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
    ISAddWeak(&gForcedElements, element);
    return NO;
}

- (void)_handleResizeResult:(NSInteger)result withContainerView:(id)containerView {
    gHandlingResize = gEnabled;
    %orig;
    gHandlingResize = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}

%end

%hook SBSystemApertureController
- (void)systemApertureViewController:(id)viewController containsAnyContent:(BOOL)containsAnyContent {
    %orig;
    gHasContent = containsAnyContent;
    ISUpdateIdleHiding(YES);
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}
%end

// 元件被作廢就不能再叫回來了。
%hook SBSystemApertureSceneElement
- (void)invalidate {
    [gHiddenElements removeObject:self];
    %orig;
}
%end

%hook SBSystemApertureStatusBarPillElementProvider
- (void)_invalidateElement:(id)element withReason:(id)reason {
    if (element) [gHiddenElements removeObject:element];
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
    BOOL forced = element && [gForcedElements containsObject:element];
    if ((gHandlingResize && forced) || [gHiddenElements containsObject:element]) return 0;
    return orig;
}

// 使用者往左滑(reason 3)要縮小時,直接縮到 0(隱藏),不用一格一格滑。
- (void)setPreferredLayoutMode:(NSInteger)mode reason:(NSInteger)reason {
    id element = ISElementForOverrider(self);
    if (gHandlingResize && reason == 3 && element && [gForcedElements containsObject:element]
        && mode < [(SAUILayoutSpecifyingOverrider *)self layoutMode]) {
        ISAddWeak(&gHiddenElements, element);
        %orig(0, reason);
        return;
    }
    %orig;
}

%end

%end

#pragma mark - 空閒時隱藏

static void ISUpdateIdleHiding(BOOL animated) {
    CGFloat alpha = ISIdleHidden() ? 0 : 1;
    void (^apply)(void) = ^{
        for (UIView *view in gContainerViews.allObjects) view.alpha = alpha;
        for (UIView *view in gGainMapViews.allObjects) view.layer.opacity = alpha;
        for (UIView *view in gCurtainViews.allObjects) view.layer.opacity = alpha;
    };
    if (animated) [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
    else apply();
}

// 要在 SpringBoard 啟動時就換掉 layerClass,所以這個選項切換後需要 respring。
%group IdleHooks

%hook SpringBoard
- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;
    UIWindow *host = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {   // 這個時間點 scene 還沒全部接上,舊 API 拿得到全部視窗
        if ([window isKindOfClass:objc_getClass("SBRootSceneWindow")]) { host = window; break; }
    }
#pragma clang diagnostic pop
    if (!host) return;
    gFirstGainMapLayer = YES;
    gPlaceholderView = [[objc_getClass("_SBGainMapView") alloc] initWithFrame:CGRectMake(-1.3, -0.9, 1, 1)];
    gPlaceholderView.backgroundColor = nil;
    gPlaceholderView.userInteractionEnabled = NO;
    gPlaceholderView.layer.disableUpdateMask |= 18;
    [host addSubview:gPlaceholderView];
}
%end

%hook _SBGainMapView
+ (Class)layerClass {
    if (gFirstGainMapLayer) {
        gFirstGainMapLayer = NO;
        return %orig;
    }
    return ISFakeGainMapLayer.class;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self && [self.layer isKindOfClass:ISFakeGainMapLayer.class]) {
        self.backgroundColor = UIColor.blackColor;
        ISAddWeak(&gGainMapViews, self);
        self.layer.opacity = ISIdleHidden() ? 0 : 1;
    }
    return self;
}
%end

%hook _SBSystemApertureMagiciansCurtainView
- (void)layoutSubviews {
    %orig;
    ISAddWeak(&gCurtainViews, self);
    self.layer.opacity = ISIdleHidden() ? 0 : 1;
}
%end

%hook SBSystemApertureContainerView
- (void)layoutSubviews {
    %orig;
    ISAddWeak(&gContainerViews, self);
    CGFloat alpha = ISIdleHidden() ? 0 : 1;
    if (self.alpha != alpha) self.alpha = alpha;
}
// 空閒時不要把 container 縮回感測器大小(那個縮小動畫會把黑色帶回來)。
- (void)setFrame:(CGRect)frame {
    if (ISIdleHidden()) return;
    %orig;
}
%end

// 空閒時點動態島不要有震動回饋(那裡已經沒東西了)。
%hook SBSystemApertureViewController
+ (id)_sharedFeedbackGenerator {
    return ISIdleHidden() ? nil : %orig;
}
- (BOOL)_handleImpactFeedbackAction:(id)action {
    return ISIdleHidden() ? NO : %orig;
}
%end

%end

#pragma mark - 設定與初始化

static void ISPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    ISLoadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        ISUpdateIdleHiding(YES);
        ISUpdateUnhideWindow();
    });
}

%ctor {
    @autoreleasepool {
        ISLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, ISPrefsChanged,
                                        (__bridge CFStringRef)kISReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        %init(SwipeHooks);
        if (gHideIdle) %init(IdleHooks);

        dlopen("/System/Library/PrivateFrameworks/SystemApertureUI.framework/SystemApertureUI", RTLD_NOW);
        ISOverriderForElement = (SAUILayoutSpecifyingOverrider *(*)(id))dlsym(RTLD_DEFAULT, "SAUILayoutSpecifyingOverriderForElement");
        Class overrider = objc_getClass("SAUILayoutSpecifyingOverrider");
        if (overrider) {
            %init(SystemApertureUIHooks, SAUILayoutSpecifyingOverrider = overrider);
        } else {
            NSLog(@"[IslandSwipe] SystemApertureUI not available; swipe hiding disabled");
        }
    }
}
