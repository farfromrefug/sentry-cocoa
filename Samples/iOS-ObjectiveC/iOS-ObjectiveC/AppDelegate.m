#import "AppDelegate.h"
@import CoreData;
@import Sentry;

@interface
AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Override point for customization after application launch.

    [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
        options.dsn = @"https://a92d50327ac74b8b9aa4ea80eccfb267@o447951.ingest.sentry.io/5428557";
        options.debug = YES;
        options.sessionTrackingIntervalMillis = 5000UL;
        // Sampling 100% - In Production you probably want to adjust this
        options.tracesSampleRate = @1.0;
        options.enableFileIOTracking = YES;
        options.attachScreenshot = YES;
        options.attachViewHierarchy = YES;
        options.enableUserInteractionTracing = YES;
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--io.sentry.profiling.enable"]) {
            options.profilesSampleRate = @1;
        }
    }];

    return YES;
}

#pragma mark - UISceneSession lifecycle

@end
