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
//   SBRootSceneWindow 放一個 1x1 的 _SBGainMapView 佔掉這個名額,其他 _SBGainMapView 保留真的
//   CAGainMapLayer(換成普通 CALayer 會讓系統把感測器中央排除在命中範圍外,點不到),沒內容時
//   用 layer.opacity 淡出即可。佔位一定要放在 SBRootSceneWindow,放進別的 scene 或被別的 tweak
//   套 transform / 濾鏡都會讓 backboardd 的 gain encoder 崩潰。

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
- (void)setPreferredLayoutMode:(NSInteger)mode reason:(NSInteger)reason;
@end

@protocol ISElementInfo <NSObject>
@optional
- (NSString *)clientIdentifier;
- (NSString *)elementIdentifier;
- (id)associatedApplication;
- (NSString *)_accessibilityLabel;
- (NSString *)displayName;
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

#pragma mark - 狀態

static NSString *const kISPrefsDomain = @"com.c3x14n.islandswipe";
static NSString *const kISReloadNotification = @"com.c3x14n.islandswipe/ReloadPrefs";

static BOOL gEnabled = YES;
static BOOL gHideIdle = YES;
// 自動隱藏的規則(元件 key,見 ISElementKey)和出現過的元件清單(給設定頁列出來勾選)。
static NSSet<NSString *> *gAutoHide;
static NSString *const kISSeenPath = @"/var/mobile/Library/Preferences/com.c3x14n.islandswipe.seen.plist";


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
    CFPropertyListRef rules = CFPreferencesCopyAppValue(CFSTR("autoHide"), (__bridge CFStringRef)kISPrefsDomain);
    NSMutableSet *keys = [NSMutableSet set];
    if ([(__bridge id)rules isKindOfClass:NSDictionary.class]) {
        [(__bridge NSDictionary *)rules enumerateKeysAndObjectsUsingBlock:^(NSString *key, id on, BOOL *stop) {
            if ([on respondsToSelector:@selector(boolValue)] && [on boolValue]) [keys addObject:key];
        }];
    }
    gAutoHide = keys;
    if (rules) CFRelease(rules);
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

#pragma mark - 自動隱藏指定元件

// 規則 key:SpringBoard 自己的元件(充電、鎖定、熱點…)和 systemApertureElementIdentifier* 用 elementIdentifier,
// App 的 Live Activity 用 bundle id(每次的 elementIdentifier 都不同)。
static NSString *ISElementKey(id<ISElementInfo> element) {
    NSString *elementID = [element respondsToSelector:@selector(elementIdentifier)] ? element.elementIdentifier : nil;
    NSString *client = [element respondsToSelector:@selector(clientIdentifier)] ? element.clientIdentifier : nil;
    if (client.length == 0 || [client isEqualToString:@"com.apple.springboard"]
        || [elementID hasPrefix:@"systemApertureElementIdentifier"]) return elementID;
    return client;
}

static NSString *ISElementName(id<ISElementInfo> element, NSString *key) {
    if ([element respondsToSelector:@selector(associatedApplication)]) {
        id app = element.associatedApplication;
        if ([app respondsToSelector:@selector(displayName)]) {
            NSString *name = [app displayName];
            if (name.length) return name;
        }
    }
    if ([element respondsToSelector:@selector(_accessibilityLabel)]) {
        NSString *label = element._accessibilityLabel;
        if (label.length) return label;
    }
    return key;
}

// 記到清單裡(設定頁讀這份 plist);只有新元件或名稱變了才寫檔。
static void ISRecordSeen(id<ISElementInfo> element, NSString *key) {
    NSString *name = ISElementName(element, key);
    NSString *client = [element respondsToSelector:@selector(clientIdentifier)] ? element.clientIdentifier : nil;
    NSString *elementID = [element respondsToSelector:@selector(elementIdentifier)] ? element.elementIdentifier : nil;
    NSMutableDictionary *seen = [NSMutableDictionary dictionaryWithContentsOfFile:kISSeenPath] ?: [NSMutableDictionary dictionary];
    NSDictionary *existing = seen[key];
    if ([existing isKindOfClass:NSDictionary.class] && [existing[@"name"] isEqual:name]) return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"name"] = name;
    if (client) entry[@"client"] = client;
    if (elementID) entry[@"element"] = elementID;
    entry[@"lastSeen"] = NSDate.date;
    seen[key] = entry;
    [seen writeToFile:kISSeenPath atomically:YES];
}

// 和往左滑同一條路:標成 forced、設成 mode 0(隱藏但仍註冊),往右滑一樣叫得回來。
static void ISAutoHideElement(id element) {
    SAUILayoutSpecifyingOverrider *overrider = ISOverriderForElement ? ISOverriderForElement(element) : nil;
    if (!overrider) return;
    ISAddWeak(&gForcedElements, element);
    ISAddWeak(&gHiddenElements, element);
    gHandlingResize = YES;
    [overrider setPreferredLayoutMode:0 reason:3];
    gHandlingResize = NO;
    [gApertureVC.view setNeedsLayout];
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}

static NSHashTable *gRegisteredElements;   // 兩條註冊路徑都會經過,避免記兩次

static void ISElementDidRegister(id element) {
    if (!gEnabled || !element) return;
    if ([gRegisteredElements containsObject:element]) return;
    ISAddWeak(&gRegisteredElements, element);
    NSString *key = ISElementKey(element);
    if (!key.length) return;
    ISRecordSeen(element, key);
    if (![gAutoHide containsObject:key]) return;
    // 等它排版好、overrider 建好再收(註冊當下還沒有)。
    __weak id weakElement = element;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakElement;
        if (strong && gEnabled && [gAutoHide containsObject:key]) ISAutoHideElement(strong);
    });
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

- (id)registerElement:(id)element {
    id assertion = %orig;
    if (assertion) ISElementDidRegister(element);
    return assertion;
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
    if (containsAnyContent) {
        ISUpdateIdleHiding(NO);   // 內容出現要馬上顯示
    } else {
        // 內容離開(例如展開成 App)先讓系統轉場跑完,再淡出;期間如果內容又回來就不動。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gHasContent) ISUpdateIdleHiding(YES);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{ ISUpdateUnhideWindow(); });
}
%end

// 狀態列 pill(熱點、錄影…)的 provider 是透過 controller 註冊的。
%hook SBSystemApertureController
- (id)registerElement:(id)element {
    id assertion = %orig;
    if (assertion) ISElementDidRegister(element);
    return assertion;
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

// 空閒時的黑色由 _containerSubBackgroundParent(每個 container 的 gain-map 背景、backdrop、key line)
// 和 _containerBackgroundParent(curtain)畫;把這兩層整個淡出,container 縮回感測器大小時也不會把黑色帶回來。
static NSArray<UIView *> *ISBackgroundParents(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!vc) return @[];
    NSMutableArray *views = [NSMutableArray array];
    for (NSString *name in @[@"_containerSubBackgroundParent", @"_containerBackgroundParent"]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(vc), name.UTF8String);
        UIView *view = ivar ? object_getIvar(vc, ivar) : nil;
        if ([view isKindOfClass:UIView.class]) [views addObject:view];
    }
    return views;
}

static void ISUpdateIdleHiding(BOOL animated) {
    CGFloat alpha = ISIdleHidden() ? 0 : 1;
    NSArray *parents = ISBackgroundParents();
    void (^apply)(void) = ^{
        for (UIView *view in parents) if (view.alpha != alpha) view.alpha = alpha;
        for (UIView *view in gContainerViews.allObjects) if (view.alpha != alpha) view.alpha = alpha;
        for (UIView *view in gGainMapViews.allObjects) if (view.layer.opacity != alpha) view.layer.opacity = alpha;
        for (UIView *view in gCurtainViews.allObjects) if (view.layer.opacity != alpha) view.layer.opacity = alpha;
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
    gPlaceholderView = [[objc_getClass("_SBGainMapView") alloc] initWithFrame:CGRectMake(-1.3, -0.9, 1, 1)];
    [gGainMapViews removeObject:gPlaceholderView];   // 佔位 view 要一直顯示,不跟著淡出
    gPlaceholderView.backgroundColor = nil;
    gPlaceholderView.userInteractionEnabled = NO;
    gPlaceholderView.layer.opacity = 1;
    gPlaceholderView.layer.disableUpdateMask |= 18;
    [host addSubview:gPlaceholderView];
}
%end

%hook _SBGainMapView
- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        ISAddWeak(&gGainMapViews, self);
        if (ISIdleHidden()) self.layer.opacity = 0;
    }
    return self;
}
%end

// 有內容時完全不碰這些圖層(轉場期間系統正在對它們做動畫,重設會打斷),只在空閒時壓成 0。
%hook _SBSystemApertureMagiciansCurtainView
- (void)layoutSubviews {
    %orig;
    ISAddWeak(&gCurtainViews, self);
    if (ISIdleHidden() && self.layer.opacity != 0) self.layer.opacity = 0;
}
%end

%hook SBSystemApertureContainerView
- (void)layoutSubviews {
    %orig;
    ISAddWeak(&gContainerViews, self);
    if (ISIdleHidden() && self.alpha != 0) self.alpha = 0;
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
