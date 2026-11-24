// x86sim debug test app (tests/lldb/run.sh): a UIKit app whose timer calls dbg_tick() twice a second on the main
// thread, and a worker thread that calls dbg_work() every 300 ms. C functions so upstream lldb (no Swift support) reads
// their locals. Built with -g and a .dSYM by tests/lldb/build-app.sh.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <unistd.h>

volatile long g_ticks, g_work;

__attribute__((noinline)) long dbg_tick(int n) {
    long acc = 0;
    for (int i = 0; i <= n; i++) acc += i * 3;
    g_ticks++;
    return acc;
}

__attribute__((noinline)) long dbg_work(long round) {
    long sq = round * round;
    g_work += sq;
    return sq;
}

static void *worker(void *arg) {
    (void)arg;
    pthread_setname_np("dbgapp.worker");
    for (long r = 0;; r++) { dbg_work(r); usleep(300000); }
    return NULL;
}

@interface DbgScene : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UILabel *label;
@end
@implementation DbgScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    self.label = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 320, 40)];
    self.label.text = @"dbgapp";
    [vc.view addSubview:self.label];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    __block int n = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        long v = dbg_tick(n++ % 10 + 1);
        self.label.text = [NSString stringWithFormat:@"tick %ld -> %ld", g_ticks, v];
    }];
}
@end

@interface DbgApp : UIResponder <UIApplicationDelegate>
@end
@implementation DbgApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    pthread_t th;
    pthread_create(&th, NULL, worker, NULL);
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s
                              options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = DbgScene.class;
    return c;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DbgApp.class)); }
}
