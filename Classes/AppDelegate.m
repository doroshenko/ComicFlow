//  Copyright (C) 2010-2016 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import <sys/xattr.h>

#import "AppDelegate.h"
#import "Library.h"
#import "LibraryViewController.h"
#import "Defaults.h"
#import "Extensions_Foundation.h"
#import "Extensions_UIKit.h"
#import "NetReachability.h"

#define kUpdateDelay 1.0
#define kScreenDimmingOpacity 0.5

@implementation AppDelegate

+ (void) initialize {
  // Setup initial user defaults
  NSMutableDictionary* defaults = [[NSMutableDictionary alloc] init];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_LibraryVersion];
  [defaults setObject:[NSNumber numberWithInteger:kServerMode_Full] forKey:kDefaultKey_ServerMode];
  [defaults setObject:[NSNumber numberWithInteger:kTrialMaxUploads] forKey:kDefaultKey_UploadsRemaining];
  [defaults setObject:[NSNumber numberWithBool:NO] forKey:kDefaultKey_ScreenDimmed];
  [defaults setObject:[NSNumber numberWithDouble:0.0] forKey:kDefaultKey_RootTimestamp];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_RootScrolling];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_CurrentCollection];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_CurrentComic];
  [defaults setObject:[NSNumber numberWithInteger:kSortingMode_ByStatus] forKey:kDefaultKey_SortingMode];
  [defaults setObject:[NSNumber numberWithInteger:0] forKey:kDefaultKey_LaunchCount];
  [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
  [defaults release];
  
  // Seed random generator
  srandomdev();
}

+ (AppDelegate*) sharedDelegate {
  return (AppDelegate*)[[UIApplication sharedApplication] delegate];
}

- (void) awakeFromNib {
  [super awakeFromNib];

  // Initialize library
  XLOG_CHECK([LibraryConnection mainConnection]);
}

- (void) _updateTimer:(NSTimer*)timer {
  if ([[LibraryUpdater sharedUpdater] isUpdating]) {
    [_updateTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:kUpdateDelay]];
  } else {
    [[LibraryUpdater sharedUpdater] update:NO];
  }
}

- (void) updateLibrary {
  [self _updateTimer:nil];
}

- (BOOL) application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  [super application:application didFinishLaunchingWithOptions:launchOptions];
  
#if TARGET_IPHONE_SIMULATOR
  // Log Documents folder path
  XLOG_VERBOSE(@"Documents folder location: %@", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]);
#endif
  
  // Prevent backup of Documents directory as it contains only "offline data" (iOS 5.0.1 and later)
  NSString* documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
  u_int8_t value = 1;
  int result = setxattr([documentsPath fileSystemRepresentation], "com.apple.MobileBackup", &value, sizeof(value), 0, 0);
  if (result) {
    XLOG_ERROR(@"Failed setting do-not-backup attribute on \"%@\": %s (%i)", documentsPath, strerror(result), result);
  }
  
  // Create root view controller
  self.viewController = [[[LibraryViewController alloc] initWithWindow:self.window] autorelease];
  
  // Initialize updater
  [[LibraryUpdater sharedUpdater] setDelegate:(LibraryViewController*)self.viewController];
  
  // Update library immediately
  if ([[LibraryConnection mainConnection] countObjectsOfClass:[Comic class]] == 0) {
    [[LibraryUpdater sharedUpdater] update:YES];
    [[NSUserDefaults standardUserDefaults] setInteger:kLibraryVersion forKey:kDefaultKey_LibraryVersion];
  } else {
    [[LibraryUpdater sharedUpdater] update:NO];
  }
  
  // Initialize update timer
  _updateTimer = [[NSTimer alloc] initWithFireDate:[NSDate distantFuture]
                                          interval:HUGE_VAL
                                            target:self
                                          selector:@selector(_updateTimer:)
                                          userInfo:nil
                                           repeats:YES];
  [[NSRunLoop currentRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
  
  // Initialize web server
  [[WebServer sharedWebServer] setDelegate:self];
  
  // Show window
  self.window.backgroundColor = nil;
  self.window.rootViewController = self.viewController;
  [self.window makeKeyAndVisible];
  
  // Initialize dimming window
  _dimmingWindow = [[UIWindow alloc] initWithFrame:([UIScreen instancesRespondToSelector:@selector(nativeBounds)] ? [[UIScreen mainScreen] nativeBounds] : [[UIScreen mainScreen] bounds])];
  _dimmingWindow.userInteractionEnabled = NO;
  _dimmingWindow.windowLevel = UIWindowLevelStatusBar;
  _dimmingWindow.backgroundColor = [UIColor blackColor];
  _dimmingWindow.alpha = 0.0;
  _dimmingWindow.hidden = YES;
  _dimmingWindow.rootViewController = [[UIViewController alloc] init];
  _dimmingWindow.rootViewController.view.hidden = YES;
  if ([[NSUserDefaults standardUserDefaults] boolForKey:kDefaultKey_ScreenDimmed]) {
    [self setScreenDimmed:YES];
  }
  
  return YES;
}

- (BOOL) application:(UIApplication*)application openURL:(NSURL*)url sourceApplication:(NSString*)sourceApplication annotation:(id)annotation {
  XLOG_VERBOSE(@"Opening \"%@\"", url);
  if ([url isFileURL]) {
    NSString* file = [[url path] lastPathComponent];
    NSString* destinationPath = [[LibraryConnection libraryRootPath] stringByAppendingPathComponent:file];
    if ([[NSFileManager defaultManager] moveItemAtPath:[url path] toPath:destinationPath error:NULL]) {
      [_updateTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:kUpdateDelay]];
      [[AppDelegate sharedInstance] showAlertWithTitle:NSLocalizedString(@"INBOX_ALERT_TITLE", nil)
                                               message:[NSString stringWithFormat:NSLocalizedString(@"INBOX_ALERT_MESSAGE", nil), file]
                                                button:NSLocalizedString(@"INBOX_ALERT_BUTTON", nil)];
      [self logEvent:@"app.open"];
      return YES;
    }
  }
  return NO;
}

- (void) saveState {
  [(LibraryViewController*)self.viewController saveState];
}

- (BOOL) isScreenDimmed {
  return [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultKey_ScreenDimmed];
}

- (void) setScreenDimmed:(BOOL)flag {
  if (flag) {
    _dimmingWindow.hidden = NO;
  }
  [UIView animateWithDuration:(1.0 / 3.0) animations:^{
    _dimmingWindow.alpha = flag ? kScreenDimmingOpacity : 0.0;
  } completion:^(BOOL finished) {
    if (!flag) {
      _dimmingWindow.hidden = YES;
    }
  }];
  [[NSUserDefaults standardUserDefaults] setBool:flag forKey:kDefaultKey_ScreenDimmed];
}

@end

@implementation AppDelegate (WebServer)

- (NSString*) _serverMode {
  switch ([[NSUserDefaults standardUserDefaults] integerForKey:kDefaultKey_ServerMode]) {
    case kServerMode_Limited: return @"Limited";
    case kServerMode_Trial: return @"Trial";
    case kServerMode_Full: return @"Full";
  }
  return nil;
}

- (void) webServerDidConnect:(WebServer*)server {
  [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
}

- (void) webServerDidDownloadComic:(WebServer*)server {
  [self logEvent:@"server.download" withParameterName:@"mode" value:[self _serverMode]];
}

- (void) webServerDidUploadComic:(WebServer*)server {
  [self logEvent:@"server.upload" withParameterName:@"mode" value:[self _serverMode]];
  _needsUpdate = YES;
  
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults integerForKey:kDefaultKey_ServerMode] == kServerMode_Trial) {
    NSUInteger count = [defaults integerForKey:kDefaultKey_UploadsRemaining];
    count = count - 1;
    if (count > 0) {
      XLOG_VERBOSE(@"Web Server trial has %i uploads left", (int)count);
      [defaults setInteger:count forKey:kDefaultKey_UploadsRemaining];
    } else {
      [defaults setInteger:kServerMode_Limited forKey:kDefaultKey_ServerMode];
      [defaults removeObjectForKey:kDefaultKey_UploadsRemaining];
      XLOG_VERBOSE(@"Web Server trial has ended");
    }
    [defaults synchronize];
  }
}

- (void) webServerDidUpdate:(WebServer*)server {
  _needsUpdate = YES;
}

- (void) webServerDidDisconnect:(WebServer*)server {
  [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
  
  if (_needsUpdate) {
    [self _updateTimer:nil];
    _needsUpdate = NO;
  }
}

@end

@implementation AppDelegate (Events)

- (void) logEvent:(NSString*)event {
  [self logEvent:event withParameterName:nil value:nil];
}

- (void) logEvent:(NSString*)event withParameterName:(NSString*)name value:(NSString*)value {
  if (name && value) {
    XLOG_VERBOSE(@"<EVENT> %@ ('%@' = '%@')", event, name, value);
    // TODO
  } else {
    XLOG_VERBOSE(@"<EVENT> %@", event);
    // TODO
  }
}

- (void) logPageView {
  XLOG_VERBOSE(@"<PAGE VIEW>");
  // TODO
}

@end
