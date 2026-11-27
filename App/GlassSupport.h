#import <UIKit/UIKit.h>
UIVisualEffect *TMCGlassEffect(BOOL interactive);
UIButtonConfiguration *TMCButtonConfiguration(BOOL prominent);
// Configure the chat item only; shared navigation bar styling stays untouched.
UINavigationBarAppearance *TMCTransparentChatBarAppearance(void);
@interface TMCNavigationController : UINavigationController
@end

/// dylix 风格的卡片 cell：图标 + 标题 + 副标题，背景是圆角卡片
/// （iOS 26 走 UIGlassEffect，低版本退回 secondarySystemGroupedBackground）。
/// 工作台 / 设置 / 执行环境 / Theos 工具链页统一用它，避免每页各写一套。
@interface TMCCardCell : UITableViewCell
+ (instancetype)cellInTable:(UITableView *)table reuseIdentifier:(NSString *)identifier;
- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                    symbol:(NSString *)symbol
                      tint:(UIColor *)tint;
@end

/// 让表格呈「卡片列表」：去分隔线、行高自适应、分组背景色。
void TMCCardTableStyle(UITableView *table);
