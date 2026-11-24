// x86sim profile test app (tests/profile/run.sh): a UIKit app with a CPU-heavy worker thread ("prof.worker":
// prof_round -> prof_hot -> prof_leaf, profwork.h) and a UI animation on the main thread (a view rotated by a
// CADisplayLink every frame, so the main thread and the render path stay busy too).
#import <UIKit/UIKit.h>
#include "profwork.h"

@interface ProfScene : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UIView *spinner;
@property (strong, nonatomic) UILabel *label;
@property (nonatomic) double angle;
@end
@implementation ProfScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    self.spinner = [[UIView alloc] initWithFrame:CGRectMake(120, 260, 140, 140)];
    self.spinner.backgroundColor = UIColor.systemBlueColor;
    self.spinner.layer.cornerRadius = 24;
    [vc.view addSubview:self.spinner];
    self.label = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 340, 40)];
    self.label.text = @"profapp";
    [vc.view addSubview:self.label];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    prof_start_worker();
}
- (void)frame:(CADisplayLink *)dl {
    self.angle += 0.05;
    self.spinner.transform = CGAffineTransformMakeRotation(self.angle);
    self.label.text = [NSString stringWithFormat:@"rounds %ld", g_prof_rounds];
}
@end

@interface ProfDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProfDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = ProfScene.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProfDelegate.class)); }
}
