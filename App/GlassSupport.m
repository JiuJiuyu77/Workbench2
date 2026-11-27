#import "GlassSupport.h"
#import <objc/message.h>
UIVisualEffect *TMCGlassEffect(BOOL interactive){
 if(UIAccessibilityIsReduceTransparencyEnabled())return nil;
 if(@available(iOS 26.0,*)){
  Class cls=NSClassFromString(@"UIGlassEffect");SEL factory=NSSelectorFromString(@"effectWithStyle:");
  if([cls respondsToSelector:factory]){UIVisualEffect *effect=((id(*)(id,SEL,NSInteger))objc_msgSend)(cls,factory,0);SEL setter=NSSelectorFromString(@"setInteractive:");if([effect respondsToSelector:setter])((void(*)(id,SEL,BOOL))objc_msgSend)(effect,setter,interactive&&!UIAccessibilityIsReduceMotionEnabled());return effect;}
 }
 return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
}
UIButtonConfiguration *TMCButtonConfiguration(BOOL prominent){
 if(@available(iOS 26.0,*))if(!UIAccessibilityIsReduceTransparencyEnabled()){
  SEL factory=NSSelectorFromString(prominent?@"prominentGlassButtonConfiguration":@"glassButtonConfiguration");
  if([UIButtonConfiguration respondsToSelector:factory])return ((id(*)(id,SEL))objc_msgSend)(UIButtonConfiguration.class,factory);
 }
 return prominent?UIButtonConfiguration.filledButtonConfiguration:UIButtonConfiguration.tintedButtonConfiguration;
}
UINavigationBarAppearance *TMCTransparentChatBarAppearance(void){
 UINavigationBarAppearance *bar=[UINavigationBarAppearance new];[bar configureWithTransparentBackground];bar.backgroundEffect=nil;bar.backgroundColor=UIColor.clearColor;bar.shadowColor=UIColor.clearColor;bar.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.labelColor};bar.largeTitleTextAttributes=@{NSForegroundColorAttributeName:UIColor.labelColor};return bar;
}
// UINavigationBar owns its glass and scroll-edge rendering. Never insert an
// effect view into the system bar: its internal layering changes across iOS.
static void NavigationTrace(NSString *message){static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("com.xuegao.workbench.navigation.trace",DISPATCH_QUEUE_SERIAL);});NSString *line=[NSString stringWithFormat:@"%.3f %@\n",NSProcessInfo.processInfo.systemUptime,message];dispatch_async(queue,^{NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;NSString *path=[docs stringByAppendingPathComponent:@"navigation-performance.log"];NSFileManager *fm=NSFileManager.defaultManager;if([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]>262144)[fm removeItemAtPath:path error:nil];if(![fm fileExistsAtPath:path])[fm createFileAtPath:path contents:nil attributes:nil];NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:path];@try{[file seekToEndOfFile];[file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];}@catch(NSException *exception){}[file closeFile];});}
@interface TMCNavigationController ()
@property (weak) UIViewController *workspaceObservedTop;
@property NSUInteger workspaceObservedDepth;
@end
#pragma mark - 卡片 cell

static UIView *TMCCardBackground(BOOL selected) {
    UIView *card = [UIView new];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    if (selected) {
        card.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.14];
        return card;
    }
    UIVisualEffect *effect = TMCGlassEffect(NO);
    if (effect) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [card addSubview:glass];
    } else {
        card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    }
    return card;
}

@implementation TMCCardCell

+ (instancetype)cellInTable:(UITableView *)table reuseIdentifier:(NSString *)identifier {
    NSString *cid = identifier.length ? identifier : @"TMCCardCell";
    TMCCardCell *cell = [table dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[TMCCardCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    return cell;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.backgroundView = TMCCardBackground(NO);
        self.selectedBackgroundView = TMCCardBackground(YES);
        self.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        self.textLabel.textColor = UIColor.labelColor;
        self.detailTextLabel.font = [UIFont systemFontOfSize:12];
        self.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        self.detailTextLabel.numberOfLines = 2;
        self.imageView.tintColor = UIColor.systemBlueColor;
        self.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect card = CGRectInset(self.bounds, 0, 3);
    self.backgroundView.frame = card;
    self.selectedBackgroundView.frame = card;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.accessoryView = nil;
    self.imageView.image = nil;
    self.textLabel.textColor = UIColor.labelColor;
}

- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                    symbol:(NSString *)symbol
                      tint:(UIColor *)tint {
    self.textLabel.text = title;
    self.detailTextLabel.text = detail;
    self.imageView.image = symbol.length ? [UIImage systemImageNamed:symbol] : nil;
    self.imageView.tintColor = tint ?: UIColor.systemBlueColor;
    self.accessoryView = nil;
}

@end

void TMCCardTableStyle(UITableView *table) {
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 64;
}

@implementation TMCNavigationController
- (void)applyStudioAppearance {NSInteger theme=[NSUserDefaults.standardUserDefaults integerForKey:@"StudioTheme"];UIUserInterfaceStyle style=theme==1?UIUserInterfaceStyleDark:theme==2?UIUserInterfaceStyleLight:UIUserInterfaceStyleUnspecified;if(self.overrideUserInterfaceStyle!=style)self.overrideUserInterfaceStyle=style;if(self.view.window.overrideUserInterfaceStyle!=style)self.view.window.overrideUserInterfaceStyle=style;}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self applyStudioAppearance];}
- (void)appearancePreferenceChanged:(NSNotification *)note{dispatch_async(dispatch_get_main_queue(),^{[self applyStudioAppearance];});}
- (void)dealloc{[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated{
 if(self.tabBarController)controller.hidesBottomBarWhenPushed=NO;
 NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;NSString *name=NSStringFromClass(controller.class);NavigationTrace([NSString stringWithFormat:@"push %@ begin",name]);[super pushViewController:controller animated:animated];[self notifyWorkspaceNavigation];NavigationTrace([NSString stringWithFormat:@"push %@ returned %.1fms",name,(NSProcessInfo.processInfo.systemUptime-start)*1000]);dispatch_async(dispatch_get_main_queue(),^{NavigationTrace([NSString stringWithFormat:@"push %@ next-main-turn %.1fms",name,(NSProcessInfo.processInfo.systemUptime-start)*1000]);});id<UIViewControllerTransitionCoordinator> transition=self.transitionCoordinator;if(transition)[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){NavigationTrace([NSString stringWithFormat:@"push %@ transition-ended %.1fms cancelled=%d",name,(NSProcessInfo.processInfo.systemUptime-start)*1000,context.isCancelled]);}];
}
- (void)viewDidLayoutSubviews{[super viewDidLayoutSubviews];if(self.workspaceObservedTop!=self.topViewController||self.workspaceObservedDepth!=self.viewControllers.count){self.workspaceObservedTop=self.topViewController;self.workspaceObservedDepth=self.viewControllers.count;[self notifyWorkspaceNavigation];}}
- (void)notifyWorkspaceNavigation{[[NSNotificationCenter defaultCenter] postNotificationName:@"WorkbenchWorkspaceNavigationChanged" object:self];id<UIViewControllerTransitionCoordinator> transition=self.transitionCoordinator;if(transition)[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){[[NSNotificationCenter defaultCenter] postNotificationName:@"WorkbenchWorkspaceNavigationChanged" object:self];}];}
- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];[self notifyWorkspaceNavigation];}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated{UIViewController *v=[super popViewControllerAnimated:animated];[self notifyWorkspaceNavigation];return v;}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated{NSArray *v=[super popToRootViewControllerAnimated:animated];[self notifyWorkspaceNavigation];return v;}
- (NSArray *)popToViewController:(UIViewController *)controller animated:(BOOL)animated{NSArray *v=[super popToViewController:controller animated:animated];[self notifyWorkspaceNavigation];return v;}
- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated{for(UIViewController *v in controllers)if(self.tabBarController)v.hidesBottomBarWhenPushed=NO;[super setViewControllers:controllers animated:animated];[self notifyWorkspaceNavigation];}
- (void)viewDidLoad{
 [super viewDidLoad];[self applyStudioAppearance];[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appearancePreferenceChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
 // Semantic foreground stays legible in light/dark appearance and sheets.
 self.navigationBar.tintColor=UIColor.labelColor;
}
@end
