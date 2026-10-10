/* RetroArch - A frontend for libretro.
 * Copyright (C) 2010-2014 - Hans-Kristian Arntzen
 * Copyright (C) 2011-2017 - Daniel De Matteis
 * Copyright (C) 2012-2014 - Jason Fetters
 * Copyright (C) 2014-2015 - Jay McCarthy
 *
 * RetroArch is free software: you can redistribute it and/or modify it under the terms
 * of the GNU General Public License as published by the Free Software Found-
 * ation, either version 3 of the License, or (at your option) any later version.
 *
 * RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 * * You should have received a copy of the GNU General Public License along with RetroArch.
 * If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdint.h>
#include "../../apple_runtime.h"
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

#include <sys/utsname.h>
#include <sys/xattr.h>

#include <mach/mach.h>
#include <dlfcn.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFArray.h>
#if !TARGET_OS_OSX || (MAC_OS_X_VERSION_MAX_ALLOWED >= 101400)
#import <AVFoundation/AVFoundation.h>
#endif

#ifdef HAVE_CONFIG_H
#include "../../config.h"
#endif

#ifdef __OBJC__
#include <Foundation/NSPathUtilities.h>
#include <objc/message.h>
#endif

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#include <sys/stat.h>
#include <Carbon/Carbon.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

#include <sys/sysctl.h>
#elif TARGET_OS_IPHONE
#include <UIKit/UIDevice.h>
#include <sys/sysctl.h>
#endif

#include <boolean.h>
#include <compat/apple_compat.h>
#include <retro_miscellaneous.h>
#include <file/file_path.h>
#include <streams/file_stream.h>
#include <features/features_cpu.h>
#include <string/stdstring.h>
#include <lists/dir_list.h>

#ifdef HAVE_MENU
#include "../../menu/menu_driver.h"
#endif

#ifdef HAVE_SWIFT
#if TARGET_OS_TV
#import "RetroArchTV-Swift.h"
#else
#import "RetroArch-Swift.h"
#endif
#endif

#include "../frontend_driver.h"
#include "../../file_path_special.h"
#include "../../configuration.h"
#include "../../defaults.h"
#include "../../retroarch.h"
#include "../../verbosity.h"
#include "../../msg_hash.h"
#include "../../ui/ui_companion_driver.h"
#include "../../paths.h"
#include <compat/strl.h>
#ifdef __MACH__
#include <TargetConditionals.h>
#endif

typedef enum
{
   CFApplicationDirectory           = 1,   /* Supported applications (Applications) */
   CFDemoApplicationDirectory       = 2,   /* Unsupported applications, demonstration versions (Demos) */
   CFDeveloperApplicationDirectory  = 3,   /* Developer applications (Developer/Applications). DEPRECATED - there is no one single Developer directory. */
   CFAdminApplicationDirectory      = 4,   /* System and network administration applications (Administration) */
   CFLibraryDirectory               = 5,   /* various documentation, support, and configuration files, resources (Library) */
   CFDeveloperDirectory             = 6,   /* developer resources (Developer) DEPRECATED - there is no one single Developer directory. */
   CFUserDirectory                  = 7,   /* User home directories (Users) */
   CFDocumentationDirectory         = 8,   /* Documentation (Documentation) */
   CFDocumentDirectory              = 9,   /* Documents (Documents) */
   CFCoreServiceDirectory           = 10,  /* Location of CoreServices directory (System/Library/CoreServices) */
   CFAutosavedInformationDirectory  = 11,  /* Location of autosaved documents (Documents/Autosaved) */
   CFDesktopDirectory               = 12,  /* Location of user's desktop */
   CFCachesDirectory                = 13,  /* Location of discardable cache files (Library/Caches) */
   CFApplicationSupportDirectory    = 14,  /* Location of application support files (plug-ins, etc) (Library/Application Support) */
   CFDownloadsDirectory             = 15,  /* Location of the user's "Downloads" directory */
   CFInputMethodsDirectory          = 16,  /* Input methods (Library/Input Methods) */
   CFMoviesDirectory                = 17,  /* Location of user's Movies directory (~/Movies) */
   CFMusicDirectory                 = 18,  /* Location of user's Music directory (~/Music) */
   CFPicturesDirectory              = 19,  /* Location of user's Pictures directory (~/Pictures) */
   CFPrinterDescriptionDirectory    = 20,  /* Location of system's PPDs directory (Library/Printers/PPDs) */
   CFSharedPublicDirectory          = 21,  /* Location of user's Public sharing directory (~/Public) */
   CFPreferencePanesDirectory       = 22,  /* Location of the PreferencePanes directory for use with System Preferences (Library/PreferencePanes) */
   CFApplicationScriptsDirectory    = 23,  /* Location of the user scripts folder for the calling application (~/Library/Application Scripts/code-signing-id) */
   CFItemReplacementDirectory       = 99,  /* For use with NSFileManager's URLForDirectory:inDomain:appropriateForURL:create:error: */
   CFAllApplicationsDirectory       = 100, /* all directories where applications can occur */
   CFAllLibrariesDirectory          = 101, /* all directories where resources can occur */
   CFTrashDirectory                 = 102  /* location of Trash directory */
} CFSearchPathDirectory;

typedef enum
{
   CFUserDomainMask     = 1,       /* user's home directory --- place to install user's personal items (~) */
   CFLocalDomainMask    = 2,       /* local to the current machine --- place to install items available to everyone on this machine (/Library) */
   CFNetworkDomainMask  = 4,       /* publicly available location in the local area network --- place to install items available on the network (/Network) */
   CFSystemDomainMask   = 8,       /* provided by Apple, unmodifiable (/System) */
   CFAllDomainsMask     = 0x0ffff  /* All domains: all of the above and future items */
} CFDomainMask;

#if TARGET_OS_OSX
static int speak_pid                            = 0;
#endif

static char darwin_cpu_model_name[64] = {0};

static void CFSearchPathForDirectoriesInDomains(
      char *s, size_t len)
{
#if TARGET_OS_TV
   NSSearchPathDirectory dir = NSCachesDirectory;
#else
   NSSearchPathDirectory dir = NSDocumentDirectory;
#endif
#if __has_feature(objc_arc)
   CFStringRef array_val     = (__bridge CFStringRef)[
         NSSearchPathForDirectoriesInDomains(dir,
            NSUserDomainMask, YES) firstObject];
#else
   CFStringRef array_val     = nil;
   NSArray *arr              =
      NSSearchPathForDirectoriesInDomains(dir,
            NSUserDomainMask, YES);
   if ([arr count] != 0)
      array_val              = (CFStringRef)[arr objectAtIndex:0];
#endif
   if (array_val)
      CFStringGetCString(array_val, s, len, kCFStringEncodingUTF8);
}

void CFTemporaryDirectory(char *s, size_t len)
{
#if __has_feature(objc_arc)
   CFStringRef path = (__bridge CFStringRef)NSTemporaryDirectory();
#else
   CFStringRef path = (CFStringRef)NSTemporaryDirectory();
#endif
   CFStringGetCString(path, s, len, kCFStringEncodingUTF8);
}

#if TARGET_OS_IPHONE
void get_ios_version(int *major, int *minor);
#endif

#if TARGET_OS_OSX

#define PMGMT_STRMATCH(a,b) (CFStringCompare(a, b, 0) == kCFCompareEqualTo)
#define PMGMT_GETVAL(k,v)   CFDictionaryGetValueIfPresent(dict, CFSTR(k), (const void **) v)

/* Note that AC power sources also include a
 * laptop battery it is charging. */
static void darwin_check_power_source(
      CFDictionaryRef dict,
      bool *have_ac,
      bool *have_battery,
      bool *charging,
      int  *seconds,
      int  *percent)
{
   CFStringRef strval; /* don't CFRelease() this. */
   CFBooleanRef bval;
   CFNumberRef numval;
   bool charge = false;
   bool choose = false;
   bool  is_ac = false;
   int    secs = -1;
   int  maxpct = -1;
   int     pct = -1;

   if ((PMGMT_GETVAL(kIOPSIsPresentKey, &bval)) && (bval == kCFBooleanFalse))
      return;

   if (!PMGMT_GETVAL(kIOPSPowerSourceStateKey, &strval))
      return;

   if (PMGMT_STRMATCH(strval, CFSTR(kIOPSACPowerValue)))
      is_ac = *have_ac = true;
   else if (!PMGMT_STRMATCH(strval, CFSTR(kIOPSBatteryPowerValue)))
      return; /* Not a battery? */

   if ((PMGMT_GETVAL(kIOPSIsChargingKey, &bval)) && (bval == kCFBooleanTrue))
      charge = true;

   if (PMGMT_GETVAL(kIOPSMaxCapacityKey, &numval))
   {
      SInt32 val = -1;
      CFNumberGetValue(numval, kCFNumberSInt32Type, &val);
      if (val > 0)
      {
         *have_battery = true;
         maxpct        = (int)val;
      }
   }

   if (PMGMT_GETVAL(kIOPSMaxCapacityKey, &numval))
   {
      SInt32 val = -1;
      CFNumberGetValue(numval, kCFNumberSInt32Type, &val);
      if (val > 0)
      {
         *have_battery = true;
         maxpct        = (int)val;
      }
   }

   if (PMGMT_GETVAL(kIOPSTimeToEmptyKey, &numval))
   {
      SInt32 val = -1;
      CFNumberGetValue(numval, kCFNumberSInt32Type, &val);

      /* Mac OS X reports 0 minutes until empty if you're plugged in. :( */
      if ((val == 0) && is_ac)
         val = -1; /* !!! FIXME: calc from timeToFull and capacity? */

      secs = (int)val;
      if (secs > 0)
         secs *= 60; /* value is in minutes, so convert to seconds. */
   }

   if (PMGMT_GETVAL(kIOPSCurrentCapacityKey, &numval))
   {
      SInt32 val = -1;
      CFNumberGetValue(numval, kCFNumberSInt32Type, &val);
      pct = (int) val;
   }

   if ((pct > 0) && (maxpct > 0))
      pct = (int) ((((double) pct) / ((double) maxpct)) * 100.0);

   if (pct > 100)
      pct = 100;

   /*
    * We pick the battery that claims to have the most minutes left.
    *  (failing a report of minutes, we'll take the highest percent.)
    */
   if ((secs < 0) && (*seconds < 0))
   {
      if ((pct < 0) && (*percent < 0))
         choose = true;  /* at least we know there's a battery. */
      if (pct > *percent)
         choose = true;
   }
   else if (secs > *seconds)
      choose = true;

   if (choose)
   {
      *seconds  = secs;
      *percent  = pct;
      *charging = charge;
   }
}
#endif

static void frontend_darwin_get_name(char *s, size_t len)
{
#if TARGET_OS_IPHONE
   struct utsname buffer;
   if (uname(&buffer) == 0)
      strlcpy(s, buffer.machine, len);
#elif TARGET_OS_OSX
   size_t _len = 0;
   sysctlbyname("hw.model", NULL, &_len, NULL, 0);
    if (_len)
        sysctlbyname("hw.model", s, &_len, NULL, 0);
#endif
}

static size_t frontend_darwin_get_os(char *s, size_t len, int *major, int *minor)
{
   size_t _len;
#if TARGET_OS_IPHONE
   get_ios_version(major, minor);
#if TARGET_OS_TV
   _len = strlcpy_lit(s, "tvOS", len);
#else
   _len = strlcpy_lit(s, "iOS", len);
#endif
#elif TARGET_OS_OSX
   /* The OS version cannot change while the process runs, so it is
    * read once and kept; get_os() is called from the menu's system
    * information list, which is rebuilt every time it is opened. */
   static int cached_major = 0, cached_minor = 0;

   if (!cached_major)
   {
      NSProcessInfo *pi = [NSProcessInfo processInfo];
      /* -operatingSystemVersion is 10.10. It returns a struct of three
       * NSIntegers, which is returned in memory on x86_64 and in
       * registers on arm64 - objc_msgSend against objc_msgSend_stret -
       * so it is sent through NSInvocation, which gets that right on
       * both without this file having to. Once per process, so the
       * invocation costs nothing that matters.
       * Credit for the shape: OpenJDK (openjdk/jdk d4c7db50). */
      if ([pi respondsToSelector:@selector(operatingSystemVersion)])
      {
         typedef struct
         {
            NSInteger majorVersion;
            NSInteger minorVersion;
            NSInteger patchVersion;
         } darwin_os_version_t;
         darwin_os_version_t version = {0, 0, 0};
         NSMethodSignature *sig      = [pi methodSignatureForSelector:
               @selector(operatingSystemVersion)];
         NSInvocation *invoke        = [NSInvocation invocationWithMethodSignature:sig];
         invoke.selector             = @selector(operatingSystemVersion);
         [invoke invokeWithTarget:pi];
         [invoke getReturnValue:&version];
         cached_major = (int)version.majorVersion;
         cached_minor = (int)version.minorVersion;
      }
      else
      {
         /* Before 10.10 there is Gestalt, which is deprecated since
          * 10.8 and gone from the newest SDKs' headers, so it is
          * resolved rather than called - the selectors are the
          * four-character codes 'sys1' and 'sys2'. A system old enough
          * to need this has it. */
         typedef int16_t (*darwin_gestalt_t)(uint32_t, int32_t*);
         darwin_gestalt_t gestalt = (darwin_gestalt_t)dlsym(RTLD_DEFAULT, "Gestalt");
         int32_t gmajor = 0, gminor = 0;
         if (gestalt)
         {
            gestalt(0x73797331 /* 'sys1' */, &gmajor);
            gestalt(0x73797332 /* 'sys2' */, &gminor);
         }
         cached_major = (int)gmajor;
         cached_minor = (int)gminor;
      }
      /* Never zero again, or the probe repeats every call. */
      if (!cached_major)
         cached_major = -1;
   }

   *major = (cached_major > 0) ? cached_major : 0;
   *minor = cached_minor;
   _len = strlcpy_lit(s, "OSX", len);
#endif
   return _len;
}

#if TARGET_OS_OSX
/* Maps "Application Support/RetroArch/..." and "Documents/RetroArch/..." inside
 * the seed to the matching folders on this Mac. */
static NSString *frontend_darwin_seed_target(NSString *rel,
      NSString *app_data, NSString *docs)
{
   if ([rel hasPrefix:@"Application Support/RetroArch"])
      return [app_data stringByAppendingString:
         [rel substringFromIndex:[@"Application Support/RetroArch" length]]];
   if ([rel hasPrefix:@"Documents/RetroArch"])
      return [docs stringByAppendingString:
         [rel substringFromIndex:[@"Documents/RetroArch" length]]];
   return nil;
}

/* A private build can carry the owner's setup in Contents/Resources/seed:
 * "Application Support/RetroArch" goes to application_data and
 * "Documents/RetroArch" to the documents folder. It runs before the config
 * is read and only when this Mac has no retroarch.cfg yet, so an existing
 * setup is never touched, and it never replaces a file that is already
 * there. Files listed in seed/home-paths.txt get "@HOME@" replaced with the
 * user's home folder, for settings that cannot use "~". */
/* First-run setup window. The copy runs on a worker while this window asks
 * for a profile (name and picture), a RetroAchievements account and a kiosk
 * mode password, so the minute it takes is not spent waiting. The answers
 * are written into the copied config before RetroArch reads it. */
@interface RASeedSetup : NSObject
@property (nonatomic, strong) NSPanel *win;
@property (nonatomic, strong) NSView *pageView;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSTextField *error;
@property (nonatomic, strong) NSProgressIndicator *bar;
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSButton *skipButton;
@property (nonatomic, strong) NSButton *nextButton;
@property (nonatomic, strong) NSTextField *userName;
@property (nonatomic, strong) NSImageView *avatarView;
@property (nonatomic, strong) NSString *avatarPath;
@property (nonatomic, strong) NSString *placeholderPath;
@property (nonatomic, strong) NSButton *raLogin;
@property (nonatomic, strong) NSButton *raCreate;
@property (nonatomic, strong) NSButton *raSkip;
@property (nonatomic, strong) NSTextField *raUser;
@property (nonatomic, strong) NSSecureTextField *raPass;
@property (nonatomic, strong) NSButton *raSignup;
@property (nonatomic, strong) NSSecureTextField *kioskPass;
@property (nonatomic, strong) NSSecureTextField *kioskPass2;
@property (nonatomic, strong) NSMutableArray *pages;
@property (nonatomic) NSInteger page;
@property (nonatomic) BOOL copyDone;
@property (nonatomic) BOOL finished;
@end

@implementation RASeedSetup

static NSTextField *ra_seed_label(NSString *text, CGFloat size, BOOL bold, NSRect frame)
{
   NSTextField *l = [NSTextField wrappingLabelWithString:text];
   [l setFont:bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size]];
   [l setFrame:frame];
   return l;
}

- (NSView *)newPage
{
   NSView *v = [[NSView alloc] initWithFrame:[self.pageView bounds]];
   [self.pages addObject:v];
   return v;
}

- (void)buildWithPlaceholder:(NSString *)placeholder
{
   NSView *view, *p;
   NSButton *choose;

   self.pages           = [NSMutableArray array];
   self.placeholderPath = placeholder;
   self.win = [[NSPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, 540, 400)
      styleMask:NSWindowStyleMaskTitled
      backing:NSBackingStoreBuffered defer:NO];
   [self.win setTitle:@"RetroArch - MacOS-ARM-Nobz Edition"];
   [self.win setLevel:NSFloatingWindowLevel];
   [self.win setReleasedWhenClosed:NO];
   view = [self.win contentView];

   self.pageView = [[NSView alloc] initWithFrame:NSMakeRect(0, 120, 540, 280)];
   [view addSubview:self.pageView];

   /* Page 1: profile */
   p = [self newPage];
   [p addSubview:ra_seed_label(@"Welcome! Let's set up RetroArch", 16, YES, NSMakeRect(24, 236, 492, 24))];
   [p addSubview:ra_seed_label(@"While the games' settings and artwork copy in the background, create your profile. Your picture appears in the top-right corner of the menu.", 12, NO, NSMakeRect(24, 192, 492, 36))];
   [p addSubview:ra_seed_label(@"Your name", 12, YES, NSMakeRect(24, 150, 200, 18))];
   self.userName = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 122, 260, 24)];
   [self.userName setPlaceholderString:@"Player"];
   [p addSubview:self.userName];
   self.avatarView = [[NSImageView alloc] initWithFrame:NSMakeRect(372, 82, 120, 120)];
   [self.avatarView setImageScaling:NSImageScaleProportionallyUpOrDown];
   [self.avatarView setImage:[[NSImage alloc] initWithContentsOfFile:placeholder]];
   [self.avatarView setWantsLayer:YES];
   [[self.avatarView layer] setBackgroundColor:[[NSColor colorWithWhite:0.2 alpha:1.0] CGColor]];
   [[self.avatarView layer] setCornerRadius:12];
   [p addSubview:self.avatarView];
   choose = [NSButton buttonWithTitle:@"Choose Picture..." target:self action:@selector(choosePicture:)];
   [choose setFrame:NSMakeRect(362, 44, 140, 30)];
   [p addSubview:choose];
   [p addSubview:ra_seed_label(@"No picture? A placeholder is used; you can add one later as assets/user/avatar.png.", 11, NO, NSMakeRect(24, 40, 320, 32))];

   /* Page 2: RetroAchievements */
   p = [self newPage];
   [p addSubview:ra_seed_label(@"RetroAchievements", 16, YES, NSMakeRect(24, 236, 492, 24))];
   [p addSubview:ra_seed_label(@"Achievements are switched on. Log in to earn them while you play.", 12, NO, NSMakeRect(24, 208, 492, 20))];
   self.raLogin  = [NSButton radioButtonWithTitle:@"Log in with my account" target:self action:@selector(raMode:)];
   self.raCreate = [NSButton radioButtonWithTitle:@"Create a new account" target:self action:@selector(raMode:)];
   self.raSkip   = [NSButton radioButtonWithTitle:@"Not now" target:self action:@selector(raMode:)];
   [self.raLogin setFrame:NSMakeRect(24, 176, 220, 20)];
   [self.raCreate setFrame:NSMakeRect(24, 152, 220, 20)];
   [self.raSkip setFrame:NSMakeRect(24, 128, 220, 20)];
   [self.raLogin setState:NSControlStateValueOn];
   [p addSubview:self.raLogin];
   [p addSubview:self.raCreate];
   [p addSubview:self.raSkip];
   self.raSignup = [NSButton buttonWithTitle:@"Open the Sign-Up Page" target:self action:@selector(openSignup:)];
   [self.raSignup setFrame:NSMakeRect(250, 146, 200, 30)];
   [self.raSignup setHidden:YES];
   [p addSubview:self.raSignup];
   [p addSubview:ra_seed_label(@"Username", 12, YES, NSMakeRect(24, 96, 120, 18))];
   self.raUser = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 68, 220, 24)];
   [p addSubview:self.raUser];
   [p addSubview:ra_seed_label(@"Password", 12, YES, NSMakeRect(264, 96, 120, 18))];
   self.raPass = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(264, 68, 220, 24)];
   [p addSubview:self.raPass];
   [p addSubview:ra_seed_label(@"New accounts are created on the RetroAchievements website. Sign up there, then enter the account here.", 11, NO, NSMakeRect(24, 24, 492, 32))];

   /* Page 3: kiosk mode password */
   p = [self newPage];
   [p addSubview:ra_seed_label(@"Kiosk mode password", 16, YES, NSMakeRect(24, 236, 492, 24))];
   [p addSubview:ra_seed_label(@"Kiosk mode hides all the settings so nobody can change the setup. Switching it on or off always takes this password. Kiosk mode stays off for now; turn it on in Settings > User Interface.", 12, NO, NSMakeRect(24, 176, 492, 52))];
   [p addSubview:ra_seed_label(@"Password", 12, YES, NSMakeRect(24, 136, 160, 18))];
   self.kioskPass = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(24, 108, 220, 24)];
   [p addSubview:self.kioskPass];
   [p addSubview:ra_seed_label(@"Password again", 12, YES, NSMakeRect(264, 136, 160, 18))];
   self.kioskPass2 = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(264, 108, 220, 24)];
   [p addSubview:self.kioskPass2];
   [p addSubview:ra_seed_label(@"Skip it to set one later: switching kiosk mode on asks for a new password the first time.", 11, NO, NSMakeRect(24, 60, 492, 32))];

   /* Buttons, messages and the copy progress */
   self.error = ra_seed_label(@"", 11, NO, NSMakeRect(24, 92, 492, 18));
   [self.error setTextColor:[NSColor systemRedColor]];
   [view addSubview:self.error];
   self.backButton = [NSButton buttonWithTitle:@"Back" target:self action:@selector(back:)];
   self.skipButton = [NSButton buttonWithTitle:@"Skip" target:self action:@selector(skip:)];
   self.nextButton = [NSButton buttonWithTitle:@"Next" target:self action:@selector(next:)];
   [self.backButton setFrame:NSMakeRect(20, 54, 90, 30)];
   [self.skipButton setFrame:NSMakeRect(326, 54, 90, 30)];
   [self.nextButton setFrame:NSMakeRect(424, 54, 100, 30)];
   [self.nextButton setKeyEquivalent:@"\r"];
   [view addSubview:self.backButton];
   [view addSubview:self.skipButton];
   [view addSubview:self.nextButton];

   self.bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 30, 492, 16)];
   [self.bar setIndeterminate:YES];
   [self.bar setUsesThreadedAnimation:YES];
   [self.bar startAnimation:nil];
   [view addSubview:self.bar];
   self.status = ra_seed_label(@"Getting ready...", 11, NO, NSMakeRect(24, 8, 492, 16));
   [self.status setTextColor:[NSColor secondaryLabelColor]];
   [view addSubview:self.status];

   self.page = 0;
   [self showPage];
   [self.win center];
   [NSApp activateIgnoringOtherApps:YES];
   [self.win makeKeyAndOrderFront:nil];
   [self.win makeFirstResponder:self.userName];
}

- (void)showPage
{
   NSInteger i;
   for (i = 0; i < (NSInteger)[self.pages count]; i++)
   {
      NSView *v = [self.pages objectAtIndex:i];
      if (i == self.page && ![v superview])
         [self.pageView addSubview:v];
      else if (i != self.page && [v superview])
         [v removeFromSuperview];
   }
   [self.error setStringValue:@""];
   [self.backButton setHidden:self.page == 0];
   [self updateFinish];
}

- (void)updateFinish
{
   BOOL last = self.page == (NSInteger)[self.pages count] - 1;
   if (!last)
   {
      [self.nextButton setTitle:@"Next"];
      [self.nextButton setEnabled:YES];
      [self.skipButton setEnabled:YES];
      return;
   }
   [self.nextButton setTitle:@"Finish"];
   [self.nextButton setEnabled:self.copyDone];
   [self.skipButton setEnabled:self.copyDone];
}

- (void)raMode:(id)sender
{
   BOOL skip = [self.raSkip state] == NSControlStateValueOn;
   [self.raSignup setHidden:[self.raCreate state] != NSControlStateValueOn];
   [self.raUser setEnabled:!skip];
   [self.raPass setEnabled:!skip];
}

- (void)openSignup:(id)sender
{
   [[NSWorkspace sharedWorkspace] openURL:
      [NSURL URLWithString:@"https://retroachievements.org/createaccount.php"]];
}

- (void)choosePicture:(id)sender
{
   NSOpenPanel *panel = [NSOpenPanel openPanel];
   NSImage *img;
   [panel setAllowedFileTypes:@[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"tif", @"gif", @"bmp", @"webp"]];
   [panel setAllowsMultipleSelection:NO];
   [panel setMessage:@"Choose a profile picture"];
   [panel setLevel:NSModalPanelWindowLevel];
   if ([panel runModal] != NSModalResponseOK)
      return;
   img = [[NSImage alloc] initWithContentsOfURL:[[panel URLs] firstObject]];
   if (!img)
   {
      [self.error setStringValue:@"That file isn't a picture RetroArch can use."];
      return;
   }
   self.avatarPath = [[[panel URLs] firstObject] path];
   [self.avatarView setImage:img];
   [self.error setStringValue:@""];
}

/* Config values are written in quotes, so a quote can't be part of them */
static BOOL ra_seed_value_ok(NSString *s)
{
   return [s rangeOfString:@"\""].location == NSNotFound;
}

- (BOOL)checkPage
{
   if (self.page == 0 && !ra_seed_value_ok([self.userName stringValue]))
   {
      [self.error setStringValue:@"Your name can't contain a quotation mark (\")."];
      return NO;
   }
   if (self.page == 1 && [self.raSkip state] != NSControlStateValueOn)
   {
      BOOL hasUser = [[self.raUser stringValue] length] > 0;
      BOOL hasPass = [[self.raPass stringValue] length] > 0;
      if (hasUser != hasPass)
      {
         [self.error setStringValue:@"Enter both the username and the password, or choose \"Not now\"."];
         return NO;
      }
      if (!ra_seed_value_ok([self.raUser stringValue]) || !ra_seed_value_ok([self.raPass stringValue]))
      {
         [self.error setStringValue:@"The username and password can't contain a quotation mark (\")."];
         return NO;
      }
   }
   if (self.page == 2)
   {
      NSString *a = [self.kioskPass stringValue];
      NSString *b = [self.kioskPass2 stringValue];
      if (([a length] || [b length]) && ![a isEqualToString:b])
      {
         [self.error setStringValue:@"The two kiosk passwords don't match."];
         return NO;
      }
      if (!ra_seed_value_ok(a))
      {
         [self.error setStringValue:@"The password can't contain a quotation mark (\")."];
         return NO;
      }
   }
   return YES;
}

- (void)clearPage
{
   if (self.page == 0)
   {
      [self.userName setStringValue:@""];
      self.avatarPath = nil;
      [self.avatarView setImage:[[NSImage alloc] initWithContentsOfFile:self.placeholderPath]];
   }
   else if (self.page == 1)
   {
      [self.raSkip setState:NSControlStateValueOn];
      [self raMode:nil];
   }
   else if (self.page == 2)
   {
      [self.kioskPass setStringValue:@""];
      [self.kioskPass2 setStringValue:@""];
   }
}

- (void)advance
{
   if (self.page == (NSInteger)[self.pages count] - 1)
   {
      self.finished = YES;
      return;
   }
   self.page++;
   [self showPage];
}

- (void)next:(id)sender { if ([self checkPage]) [self advance]; }
- (void)skip:(id)sender { [self clearPage]; [self advance]; }
- (void)back:(id)sender { if (self.page > 0) { self.page--; [self showPage]; } }

- (void)setProgress:(NSUInteger)copied of:(NSUInteger)total
{
   if (!total)
      return;
   if ([self.bar isIndeterminate])
   {
      [self.bar setIndeterminate:NO];
      [self.bar setMaxValue:(double)total];
   }
   [self.bar setDoubleValue:(double)copied];
   [self.status setStringValue:self.copyDone
      ? @"Everything is copied. Finish when you're ready."
      : [NSString stringWithFormat:@"Copying the setup: %lu of %lu files",
         (unsigned long)copied, (unsigned long)total]];
   [self updateFinish];
}
@end

/* Sets "key = value" in a config file's text, replacing the line if the key is there */
static NSString *ra_seed_cfg_set(NSString *text, NSString *key, NSString *value)
{
   NSString *line        = [NSString stringWithFormat:@"%@ = \"%@\"", key, value];
   NSMutableArray *lines = [NSMutableArray arrayWithArray:
      [text componentsSeparatedByString:@"\n"]];
   NSUInteger i;
   for (i = 0; i < [lines count]; i++)
   {
      NSString *l = [lines objectAtIndex:i];
      if ([l hasPrefix:[key stringByAppendingString:@" "]]
            || [l hasPrefix:[key stringByAppendingString:@"="]])
      {
         [lines replaceObjectAtIndex:i withObject:line];
         return [lines componentsJoinedByString:@"\n"];
      }
   }
   if ([lines count] && [[lines lastObject] length] == 0)
      [lines insertObject:line atIndex:[lines count] - 1];
   else
      [lines addObject:line];
   return [lines componentsJoinedByString:@"\n"];
}

/* Saves the picture as a 256x256 PNG, cropped to a square from the middle */
static void ra_seed_save_avatar(NSString *from, NSString *to)
{
   NSImage *src = [[NSImage alloc] initWithContentsOfFile:from];
   NSBitmapImageRep *rep;
   NSSize sz;
   CGFloat side;
   NSData *png;

   if (!src)
      return;
   sz   = [src size];
   side = MIN(sz.width, sz.height);
   if (side <= 0)
      return;
   rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
      pixelsWide:256 pixelsHigh:256 bitsPerSample:8 samplesPerPixel:4
      hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
      bytesPerRow:0 bitsPerPixel:0];
   [NSGraphicsContext saveGraphicsState];
   [NSGraphicsContext setCurrentContext:
      [NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
   [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
   [src drawInRect:NSMakeRect(0, 0, 256, 256)
      fromRect:NSMakeRect((sz.width - side) / 2, (sz.height - side) / 2, side, side)
      operation:NSCompositingOperationCopy fraction:1.0];
   [NSGraphicsContext restoreGraphicsState];
   png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
   [[NSFileManager defaultManager] createDirectoryAtPath:
      [to stringByDeletingLastPathComponent] withIntermediateDirectories:YES
      attributes:nil error:nil];
   [png writeToFile:to atomically:YES];
}

/* Writes the setup window's answers into the freshly copied config */
static void ra_seed_apply(RASeedSetup *setup, NSString *app_data)
{
   NSString *cfg_path = [app_data stringByAppendingPathComponent:@"config/retroarch.cfg"];
   NSString *key_path = [app_data stringByAppendingPathComponent:@"config/retroarch-keychain.cfg"];
   NSString *cfg      = [NSString stringWithContentsOfFile:cfg_path
      encoding:NSUTF8StringEncoding error:nil];
   NSString *keys     = [NSString stringWithContentsOfFile:key_path
      encoding:NSUTF8StringEncoding error:nil];
   NSString *name     = [[setup.userName stringValue]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
   BOOL keys_changed  = NO;

   if (!keys)
      keys = @"";

   if (cfg)
   {
      cfg = ra_seed_cfg_set(cfg, @"cheevos_enable", @"true");
      if ([name length])
         cfg = ra_seed_cfg_set(cfg, @"netplay_nickname", name);
      [cfg writeToFile:cfg_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
   }

   if ([setup.raSkip state] != NSControlStateValueOn
         && [[setup.raUser stringValue] length] && [[setup.raPass stringValue] length])
   {
      keys = ra_seed_cfg_set(keys, @"cheevos_username", [setup.raUser stringValue]);
      keys = ra_seed_cfg_set(keys, @"cheevos_password", [setup.raPass stringValue]);
      keys_changed = YES;
   }
   if ([[setup.kioskPass stringValue] length])
   {
      keys = ra_seed_cfg_set(keys, @"kiosk_mode_password", [setup.kioskPass stringValue]);
      keys_changed = YES;
   }
   if (keys_changed)
   {
      if (![keys hasSuffix:@"\n"])
         keys = [keys stringByAppendingString:@"\n"];
      [keys writeToFile:key_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      chmod([key_path fileSystemRepresentation], 0600);
   }

   if (setup.avatarPath)
      ra_seed_save_avatar(setup.avatarPath,
            [app_data stringByAppendingPathComponent:@"assets/user/avatar.png"]);
}

static void frontend_darwin_install_seed(const char *application_data,
      const char *documents_dir)
{
   @autoreleasepool
   {
      NSFileManager *fm  = [NSFileManager defaultManager];
      NSString *seed     = [[[NSBundle mainBundle] resourcePath]
         stringByAppendingPathComponent:@"seed"];
      NSString *app_data = [NSString stringWithUTF8String:application_data];
      NSString *docs     = [NSString stringWithUTF8String:documents_dir];
      NSString *list;
      RASeedSetup *setup;
      BOOL is_dir        = NO;
      __block volatile BOOL done        = NO;
      __block volatile NSUInteger total  = 0;
      __block volatile NSUInteger copied = 0;

      if (![fm fileExistsAtPath:seed isDirectory:&is_dir] || !is_dir)
         return;
      if ([fm fileExistsAtPath:[app_data
            stringByAppendingPathComponent:@"config/retroarch.cfg"]])
         return;

      RARCH_LOG("[Seed] No config yet, installing the bundled setup.\n");
      setup = [RASeedSetup new];
      [setup buildWithPlaceholder:[seed stringByAppendingPathComponent:
         @"Application Support/RetroArch/assets/user/avatar-placeholder.png"]];

      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
         @autoreleasepool
         {
            NSFileManager *wfm = [NSFileManager new];
            NSString *rel;
            NSDirectoryEnumerator *it;
            BOOL dir           = NO;
            NSUInteger count   = 0;

            it = [wfm enumeratorAtPath:seed];
            while ((rel = [it nextObject]))
               if (![[[it fileAttributes] fileType]
                     isEqualToString:NSFileTypeDirectory])
                  count++;
            total = count;

            it = [wfm enumeratorAtPath:seed];
            while ((rel = [it nextObject]))
            {
               NSString *from = [seed stringByAppendingPathComponent:rel];
               NSString *to   = frontend_darwin_seed_target(rel, app_data, docs);
               if (!to)
                  continue;
               if ([wfm fileExistsAtPath:from isDirectory:&dir] && dir)
               {
                  [wfm createDirectoryAtPath:to withIntermediateDirectories:YES
                     attributes:nil error:nil];
                  continue;
               }
               copied++;
               if ([wfm fileExistsAtPath:to])
                  continue;
               if ([wfm copyItemAtPath:from toPath:to error:nil])
                  /* Cores copied out of a downloaded app would otherwise be
                   * refused by Gatekeeper when they are loaded. */
                  removexattr([to fileSystemRepresentation],
                        "com.apple.quarantine", XATTR_NOFOLLOW);
            }
         }
         done = YES;
      });

      /* Run the window until the copy is done and the user has finished.
       * Cmd-Q is held back so RetroArch can't quit halfway through; the
       * edit shortcuts are routed by hand, as there is no Edit menu yet. */
      while (!(done && setup.finished))
      {
         @autoreleasepool
         {
            NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
               untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
               inMode:NSDefaultRunLoopMode dequeue:YES];
            if (ev && [ev type] == NSEventTypeKeyDown
                   && ([ev modifierFlags] & NSEventModifierFlagCommand))
            {
               NSString *k = [[ev charactersIgnoringModifiers] lowercaseString];
               SEL action  = NULL;
               if ([k isEqualToString:@"v"])      action = @selector(paste:);
               else if ([k isEqualToString:@"c"]) action = @selector(copy:);
               else if ([k isEqualToString:@"x"]) action = @selector(cut:);
               else if ([k isEqualToString:@"a"]) action = @selector(selectAll:);
               if (action)
                  [NSApp sendAction:action to:nil from:nil];
               ev = nil;
            }
            if (ev)
               [NSApp sendEvent:ev];
            if (done && !setup.copyDone)
               setup.copyDone = YES;
            [setup setProgress:copied of:total];
         }
      }

      list = [NSString stringWithContentsOfFile:
         [seed stringByAppendingPathComponent:@"home-paths.txt"]
         encoding:NSUTF8StringEncoding error:nil];
      for (NSString *line in [list componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]])
      {
         NSString *path = frontend_darwin_seed_target(line, app_data, docs);
         NSString *text = path ? [NSString stringWithContentsOfFile:path
            encoding:NSUTF8StringEncoding error:nil] : nil;
         if (text)
            [[text stringByReplacingOccurrencesOfString:@"@HOME@"
               withString:NSHomeDirectory()]
               writeToFile:path atomically:YES
               encoding:NSUTF8StringEncoding error:nil];
      }

      ra_seed_apply(setup, app_data);
      [setup.win orderOut:nil];
      /* Shows the "finishing setup" and "ready" messages once RetroArch is up */
      retroarch_first_run_setup_installed();
      RARCH_LOG("[Seed] Done.\n");
   }
}
#endif

static void frontend_darwin_get_env(int *argc, char *argv[],
      void *args, void *params_data)
{
   char assets_zip_path[PATH_MAX_LENGTH];
   CFURLRef bundle_url;
   CFStringRef bundle_path;
   char temp_dir[DIR_MAX_LENGTH]           = {0};
   char bundle_path_buf[PATH_MAX_LENGTH]   = {0};
   char documents_dir_buf[DIR_MAX_LENGTH]  = {0};
   char application_data[PATH_MAX_LENGTH]  = {0};
   CFBundleRef bundle                      = CFBundleGetMainBundle();

   if (!bundle)
      return;

   bundle_url    = CFBundleCopyBundleURL(bundle);
   bundle_path   = CFURLCopyFileSystemPath(bundle_url, kCFURLPOSIXPathStyle);
   CFStringGetCString(bundle_path, bundle_path_buf, sizeof(bundle_path_buf), kCFStringEncodingUTF8);
   CFRelease(bundle_path);
   CFRelease(bundle_url);
   path_resolve_realpath(bundle_path_buf, sizeof(bundle_path_buf), true);

#if TARGET_OS_OSX
   fill_pathname_application_data(application_data, sizeof(application_data));

   BOOL portable; /* steam || RAPortableInstall || portable.txt */
#if HAVE_STEAM
   /* For Steam, we're going to put everything next to the .app */
   portable = YES;
#else
   portable = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"RAPortableInstall"] boolValue];
   if (!portable)
   {
      char portable_buf[PATH_MAX_LENGTH] = {0};
      fill_pathname_join(portable_buf, application_data, "portable.txt", sizeof(portable_buf));
      portable = path_is_valid(portable_buf);
   }
#endif
   if (portable)
      strlcpy(documents_dir_buf, application_data, sizeof(documents_dir_buf));
   else
   {
      CFSearchPathForDirectoriesInDomains(documents_dir_buf, sizeof(documents_dir_buf));
      path_resolve_realpath(documents_dir_buf, sizeof(documents_dir_buf), true);
      strlcat(documents_dir_buf, "/RetroArch", sizeof(documents_dir_buf));
   }
#else
   CFSearchPathForDirectoriesInDomains(documents_dir_buf, sizeof(documents_dir_buf));
   path_resolve_realpath(documents_dir_buf, sizeof(documents_dir_buf), true);
   strlcat(documents_dir_buf, "/RetroArch", sizeof(documents_dir_buf));
   /* iOS and tvOS are going to put everything in the documents dir */
   strlcpy(application_data, documents_dir_buf, sizeof(application_data));
#endif

#if TARGET_OS_OSX
   if (!portable)
      frontend_darwin_install_seed(application_data, documents_dir_buf);
#endif

   /* By the time we are here:
    * bundle_path_buf is the full path of the .app
    * documents_dir_buf is where user documents go (macos: ~/Documents/RetroArch)
    * application_data is where "hidden" app data goes (macos: ~/Library/Application Support/RetroArch, ios: documents dir)

    * this stuff we expect the user to find easily, possibly sync across iCloud */
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_LOGS], documents_dir_buf, "logs", sizeof(g_defaults.dirs[DEFAULT_DIR_LOGS]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_PLAYLIST], documents_dir_buf, "playlists", sizeof(g_defaults.dirs[DEFAULT_DIR_PLAYLIST]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_RECORD_OUTPUT], documents_dir_buf, "records", sizeof(g_defaults.dirs[DEFAULT_DIR_RECORD_OUTPUT]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_RECORD_CONFIG], documents_dir_buf, "records_config", sizeof(g_defaults.dirs[DEFAULT_DIR_RECORD_CONFIG]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_SRAM], documents_dir_buf, "saves", sizeof(g_defaults.dirs[DEFAULT_DIR_SRAM]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_SCREENSHOT], documents_dir_buf, "screenshots", sizeof(g_defaults.dirs[DEFAULT_DIR_SCREENSHOT]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_SAVESTATE], documents_dir_buf, "states", sizeof(g_defaults.dirs[DEFAULT_DIR_SAVESTATE]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_SYSTEM], documents_dir_buf, "system", sizeof(g_defaults.dirs[DEFAULT_DIR_SYSTEM]));

   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_ASSETS], application_data, "assets", sizeof(g_defaults.dirs[DEFAULT_DIR_ASSETS]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_AUTOCONFIG], application_data, "autoconfig", sizeof(g_defaults.dirs[DEFAULT_DIR_AUTOCONFIG]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CHEATS], application_data, "cht", sizeof(g_defaults.dirs[DEFAULT_DIR_CHEATS]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_MENU_CONFIG], application_data, "config", sizeof(g_defaults.dirs[DEFAULT_DIR_MENU_CONFIG]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_REMAP], g_defaults.dirs[DEFAULT_DIR_MENU_CONFIG], "remaps", sizeof(g_defaults.dirs[DEFAULT_DIR_REMAP]));
#if defined(HAVE_UPDATE_CORES) || defined(HAVE_STEAM)
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CORE], application_data, "cores", sizeof(g_defaults.dirs[DEFAULT_DIR_CORE]));
#elif TARGET_OS_OSX && defined(HAVE_APPLE_STORE)
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CORE], bundle_path_buf, "Contents/Frameworks", sizeof(g_defaults.dirs[DEFAULT_DIR_CORE]));
#elif TARGET_OS_IPHONE && defined(HAVE_FRAMEWORKS)
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CORE], bundle_path_buf, "Frameworks", sizeof(g_defaults.dirs[DEFAULT_DIR_CORE]));
#else
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CORE], bundle_path_buf, "modules", sizeof(g_defaults.dirs[DEFAULT_DIR_CORE]));
#endif
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_DATABASE], application_data, "database/rdb", sizeof(g_defaults.dirs[DEFAULT_DIR_DATABASE]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CORE_ASSETS], application_data, "downloads", sizeof(g_defaults.dirs[DEFAULT_DIR_CORE_ASSETS]));
   /* -[NSBundle URLForResource:withExtension:subdirectory:] is 10.6+
    * (NS_AVAILABLE(10_6, 4_0)).  On 10.5 Leopard the selector doesn't
    * exist and the runtime throws "unrecognized selector".  Guard
    * with respondsToSelector: and fall through to the existing
    * fill_pathname_join fallback on older systems, which simply
    * won't do bundle-shipped filter auto-discovery. */
   NSURL *url = nil;
   SEL url_for_resource_sel = @selector(URLForResource:withExtension:subdirectory:);
   if ([[NSBundle mainBundle] respondsToSelector:url_for_resource_sel])
      url = [[NSBundle mainBundle] URLForResource:nil withExtension:@"dsp" subdirectory:@"filters/audio"];
   if (url)
       /* URLForResource: with a nil name returns a URL pointing at
        * the first matching .dsp file.  What we want is the directory
        * it lives in, so strip the last path component.
        *
        * The previous code used [[url baseURL] fileSystemRepresentation],
        * which was wrong on two counts: -baseURL returns nil for URLs
        * constructed absolutely (which is what URLForResource: returns),
        * so the result was a NULL source pointer into strlcpy; and on
        * pre-10.9 SDKs NSURL doesn't declare -fileSystemRepresentation,
        * so GCC resolved the selector against NSString's version with
        * an incompatible-receiver warning. */
       strlcpy(g_defaults.dirs[DEFAULT_DIR_AUDIO_FILTER], [[[url path] stringByDeletingLastPathComponent] UTF8String], sizeof(g_defaults.dirs[DEFAULT_DIR_AUDIO_FILTER]));
   else
       fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_AUDIO_FILTER], application_data, "filters/audio", sizeof(g_defaults.dirs[DEFAULT_DIR_AUDIO_FILTER]));
   url = nil;
   if ([[NSBundle mainBundle] respondsToSelector:url_for_resource_sel])
      url = [[NSBundle mainBundle] URLForResource:nil withExtension:@"filt" subdirectory:@"filters/video"];
   if (url)
       strlcpy(g_defaults.dirs[DEFAULT_DIR_VIDEO_FILTER], [[[url path] stringByDeletingLastPathComponent] UTF8String], sizeof(g_defaults.dirs[DEFAULT_DIR_VIDEO_FILTER]));
   else
       fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_VIDEO_FILTER], application_data, "filters/video", sizeof(g_defaults.dirs[DEFAULT_DIR_VIDEO_FILTER]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_CORE_INFO], application_data, "info", sizeof(g_defaults.dirs[DEFAULT_DIR_CORE_INFO]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_OVERLAY], application_data, "overlays", sizeof(g_defaults.dirs[DEFAULT_DIR_OVERLAY]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_OSK_OVERLAY], application_data, "overlays/keyboards", sizeof(g_defaults.dirs[DEFAULT_DIR_OSK_OVERLAY]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_SHADER], application_data, "shaders", sizeof(g_defaults.dirs[DEFAULT_DIR_SHADER]));
   fill_pathname_join(g_defaults.dirs[DEFAULT_DIR_THUMBNAILS], application_data, "thumbnails", sizeof(g_defaults.dirs[DEFAULT_DIR_THUMBNAILS]));

#if TARGET_OS_IPHONE
    fill_pathname_join_special(assets_zip_path,
          bundle_path_buf, "assets.zip", sizeof(assets_zip_path));
#else
    char full_resource_path_buf[PATH_MAX_LENGTH];
    char resource_path_buf[PATH_MAX_LENGTH] = {0};
    CFURLRef resource_url     = CFBundleCopyResourcesDirectoryURL(bundle);
    CFStringRef resource_path = CFURLCopyPath(resource_url);
    CFStringGetCString(resource_path, resource_path_buf, sizeof(resource_path_buf), kCFStringEncodingUTF8);
    CFRelease(resource_path);
    CFRelease(resource_url);

    fill_pathname_join_special(full_resource_path_buf,
          bundle_path_buf, resource_path_buf, sizeof(full_resource_path_buf));
    fill_pathname_join_special(assets_zip_path,
          full_resource_path_buf, "assets.zip", sizeof(assets_zip_path));
#endif

    if (path_is_valid(assets_zip_path))
    {
       settings_t *settings = config_get_ptr();
       configuration_set_string(settings,
             settings->paths.bundle_assets_src,
             assets_zip_path);
       configuration_set_string(settings,
             settings->paths.bundle_assets_dst,
             application_data
       );
       NSString *bundleVersionString = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
       NSInteger bundleVersion = [bundleVersionString integerValue] || 1;
       configuration_set_uint(settings, settings->uints.bundle_assets_extract_version_current, (uint)bundleVersion);
    }

   CFTemporaryDirectory(temp_dir, sizeof(temp_dir));
   strlcpy(g_defaults.dirs[DEFAULT_DIR_CACHE],
         temp_dir,
         sizeof(g_defaults.dirs[DEFAULT_DIR_CACHE]));

   if (!path_is_directory(g_defaults.dirs[DEFAULT_DIR_MENU_CONFIG]))
      path_mkdir(g_defaults.dirs[DEFAULT_DIR_MENU_CONFIG]);
}

static enum frontend_powerstate frontend_darwin_get_powerstate(
      int *seconds, int *percent)
{
   enum frontend_powerstate ret = FRONTEND_POWERSTATE_NONE;
#if TARGET_OS_OSX
   CFIndex i, total;
   CFArrayRef list;
   bool have_ac, have_battery, charging;
   CFTypeRef blob  = IOPSCopyPowerSourcesInfo();

   *seconds        = -1;
   *percent        = -1;

   if (!blob)
      return FRONTEND_POWERSTATE_NONE;

   if (!(list = IOPSCopyPowerSourcesList(blob)))
   {
      CFRelease(blob);
      return FRONTEND_POWERSTATE_NONE;
   }

   /* don't CFRelease() the list items, or dictionaries! */
   have_ac         = false;
   have_battery    = false;
   charging        = false;
   total           = CFArrayGetCount(list);

   for (i = 0; i < total; i++)
   {
      CFTypeRef ps = (CFTypeRef)CFArrayGetValueAtIndex(list, i);
      CFDictionaryRef dict = IOPSGetPowerSourceDescription(blob, ps);
      if (dict)
         darwin_check_power_source(dict, &have_ac, &have_battery, &charging,
               seconds, percent);
   }

   if (!have_battery)
      ret = FRONTEND_POWERSTATE_NO_SOURCE;
   else if (charging)
      ret = FRONTEND_POWERSTATE_CHARGING;
   else if (have_ac)
      ret = FRONTEND_POWERSTATE_CHARGED;
   else
      ret = FRONTEND_POWERSTATE_ON_POWER_SOURCE;

   CFRelease(list);
   CFRelease(blob);
#elif TARGET_OS_IOS
   float level;
   UIDevice *uidev = [UIDevice currentDevice];
   if (uidev)
   {
      [uidev setBatteryMonitoringEnabled:true];

      switch (uidev.batteryState)
      {
         case UIDeviceBatteryStateCharging:
            ret = FRONTEND_POWERSTATE_CHARGING;
            break;
         case UIDeviceBatteryStateFull:
            ret = FRONTEND_POWERSTATE_CHARGED;
            break;
         case UIDeviceBatteryStateUnplugged:
            ret = FRONTEND_POWERSTATE_ON_POWER_SOURCE;
            break;
         case UIDeviceBatteryStateUnknown:
            break;
      }

      level = uidev.batteryLevel;

      *percent = ((level < 0.0f) ? -1 : ((int)((level * 100) + 0.5f)));

      [uidev setBatteryMonitoringEnabled:false];
   }
#endif
   return ret;
}

#if !TARGET_OS_OSX
#ifndef CPU_ARCH_ABI64
#define CPU_ARCH_ABI64          0x01000000
#endif

#ifndef CPU_TYPE_ARM64
#define CPU_TYPE_ARM64          (CPU_TYPE_ARM | CPU_ARCH_ABI64)
#endif
#endif

static enum frontend_architecture frontend_darwin_get_arch(void)
{
#if TARGET_OS_OSX
    struct utsname buffer;

    if (uname(&buffer) != 0)
       return FRONTEND_ARCH_NONE;

   if (string_is_equal(buffer.machine, "x86_64"))
      return FRONTEND_ARCH_X86_64;
   if (string_is_equal(buffer.machine, "x86"))
      return FRONTEND_ARCH_X86;
   if (string_is_equal(buffer.machine, "Power Macintosh"))
      return FRONTEND_ARCH_PPC;
   if (string_is_equal(buffer.machine, "arm64"))
      return FRONTEND_ARCH_ARMV8;
#else
   cpu_type_t type;
   size_t _len = sizeof(type);
   sysctlbyname("hw.cputype", &type, &_len, NULL, 0);
   if (type == CPU_TYPE_X86_64)
      return FRONTEND_ARCH_X86_64;
   else if (type == CPU_TYPE_X86)
      return FRONTEND_ARCH_X86;
   else if (type == CPU_TYPE_ARM64)
      return FRONTEND_ARCH_ARMV8;
   else if (type == CPU_TYPE_ARM)
      return FRONTEND_ARCH_ARMV7;
#endif
    return FRONTEND_ARCH_NONE;
}

static int frontend_darwin_parse_drive_list(void *data, bool load_content)
{
   int ret = -1;
#if TARGET_OS_IPHONE || defined(HAVE_APPLE_STORE)
#ifdef HAVE_MENU
   struct string_list *str_list          = NULL;
   file_list_t *list                     = (file_list_t*)data;
   enum msg_hash_enums enum_idx          = load_content
      ? MENU_ENUM_LABEL_FILE_DETECT_CORE_LIST_PUSH_DIR
      : MENU_ENUM_LABEL_FILE_BROWSER_DIRECTORY;

   if (list->size == 0)
      menu_entries_append(list,
#if TARGET_OS_TV
            "~/Library/Caches/RetroArch",
#else
            "~/Documents/RetroArch",
#endif
            msg_hash_to_str(MENU_ENUM_LABEL_FILE_DETECT_CORE_LIST_PUSH_DIR),
            enum_idx,
            FILE_TYPE_DIRECTORY, 0, 0, NULL);

   str_list = string_list_new();
   // only add / if it's jailbroken
   dir_list_append(str_list, "/private/var", NULL, true, false, false, false);
   if (str_list->size > 0)
      menu_entries_append(list, "/",
            msg_hash_to_str(MENU_ENUM_LABEL_FILE_DETECT_CORE_LIST_PUSH_DIR),
            enum_idx,
            FILE_TYPE_DIRECTORY, 0, 0, NULL);
   string_list_free(str_list);

#if !TARGET_OS_TV
   if (   filebrowser_get_type() == FILEBROWSER_NONE ||
          filebrowser_get_type() == FILEBROWSER_SCAN_FILE ||
          filebrowser_get_type() == FILEBROWSER_SELECT_FILE)
      menu_entries_append(list,
                          msg_hash_to_str(MENU_ENUM_LABEL_VALUE_FILE_BROWSER_OPEN_PICKER),
                          msg_hash_to_str(MENU_ENUM_LABEL_FILE_BROWSER_OPEN_PICKER),
                          MENU_ENUM_LABEL_FILE_BROWSER_OPEN_PICKER,
                          MENU_SETTING_ACTION, 0, 0, NULL);
#endif

   ret = 0;
#endif
#endif
   return ret;
}

static const char* frontend_darwin_get_cpu_model_name(void)
{
   cpu_features_get_model_name(darwin_cpu_model_name,
         sizeof(darwin_cpu_model_name));
   return darwin_cpu_model_name;
}

static enum retro_language frontend_darwin_get_user_language(void)
{
   char s[128];
   CFArrayRef langs;
   CFStringRef langCode;
   /* CFLocaleCopyPreferredLanguages is 10.5; looked up at run time so
    * one binary builds against, and runs on, 10.4 as well. */
   CFArrayRef (*copy_langs)(void) = (CFArrayRef (*)(void))
      dlsym(RTLD_DEFAULT, "CFLocaleCopyPreferredLanguages");
   if (!copy_langs)
      return RETRO_LANGUAGE_ENGLISH;
   langs = copy_langs();
   if (!langs || CFArrayGetCount(langs) < 1)
   {
      if (langs)
         CFRelease(langs);
      return RETRO_LANGUAGE_ENGLISH;
   }
   langCode = CFArrayGetValueAtIndex(langs, 0);
   CFStringGetCString(langCode, s, sizeof(s), kCFStringEncodingUTF8);
   CFRelease(langs);
   /* iOS and OS X only support the language ID syntax consisting
    * of a language designator and optional region or script designator. */
   string_replace_all_chars(s, '-', '_');
   return retroarch_get_language_from_iso(s);
}

#if TARGET_OS_OSX
static char* accessibility_mac_language_code(const char* language)
{
   if (string_is_equal(language,"en"))
      return "Alex";
   else if (string_is_equal(language,"it"))
      return "Alice";
   else if (string_is_equal(language,"sv"))
      return "Alva";
   else if (string_is_equal(language,"fr"))
      return "Amelie";
   else if (string_is_equal(language,"de"))
      return "Anna";
   else if (string_is_equal(language,"he"))
      return "Carmit";
   else if (string_is_equal(language,"id"))
      return "Damayanti";
   else if (string_is_equal(language,"es"))
      return "Diego";
   else if (string_is_equal(language,"nl"))
      return "Ellen";
   else if (string_is_equal(language,"ro"))
      return "Ioana";
   else if (string_is_equal(language,"pt_pt"))
      return "Joana";
   else if (string_is_equal(language,"pt_bt")
         || string_is_equal(language,"pt"))
      return "Luciana";
   else if (string_is_equal(language,"th"))
      return "Kanya";
   else if (string_is_equal(language,"ja"))
      return "Kyoko";
   else if (string_is_equal(language,"sk"))
      return "Laura";
   else if (string_is_equal(language,"hi"))
      return "Lekha";
   else if (string_is_equal(language,"ar"))
      return "Maged";
   else if (string_is_equal(language,"hu"))
      return "Mariska";
   else if (string_is_equal(language,"zh_tw")
         || string_is_equal(language,"zh"))
      return "Mei-Jia";
   else if (string_is_equal(language,"el"))
      return "Melina";
   else if (string_is_equal(language,"ru"))
      return "Milena";
   else if (string_is_equal(language,"nb"))
      return "Nora";
   else if (string_is_equal(language,"da"))
      return "Sara";
   else if (string_is_equal(language,"fi"))
      return "Satu";
   else if (string_is_equal(language,"zh_hk"))
      return "Sin-ji";
   else if (string_is_equal(language,"zh_cn"))
      return "Ting-Ting";
   else if (string_is_equal(language,"tr"))
      return "Yelda";
   else if (string_is_equal(language,"ko"))
      return "Yuna";
   else if (string_is_equal(language,"pl"))
      return "Zosia";
   else if (string_is_equal(language,"cs"))
      return "Zuzana";
   return "";
}

static bool is_narrator_running_macos(void)
{
   return (kill(speak_pid, 0) == 0);
}

static bool accessibility_speak_macos(int speed,
      const char* speak_text, int priority)
{
   int pid;
   const char *voice      = get_user_language_iso639_1(false);
   char* language_speaker = accessibility_mac_language_code(voice);
   char* speeds[10]       = {"80",  "100", "125", "150", "170", "210",
                             "260", "310", "380", "450"};

   if (priority < 10 && speak_pid > 0)
   {
      /* check if old pid is running */
      if (is_narrator_running_macos())
         return true;
   }

   if (speak_pid > 0)
   {
      /* Kill the running say */
      kill(speak_pid, SIGTERM);
      speak_pid = 0;
   }

   pid = fork();
   /* Could not fork for say command */
   if (pid < 0) { }
   else if (pid > 0)
   {
      /* parent process */
      speak_pid = pid;

      /* Tell the system that we'll ignore the exit status of the child
       * process.  This prevents zombie processes. */
      signal(SIGCHLD,SIG_IGN);
   }
   else
   {
      /* child process: replace process with the say command */
      if (language_speaker && language_speaker[0] != '\0')
      {
         char* cmd[] = {"say", "-v", NULL,
                        NULL, "-r", NULL, NULL};
         cmd[2]      = language_speaker;
         cmd[3]      = (char *) speak_text;
         cmd[5]      = speeds[speed-1];
         execvp("say", cmd);
      }
      else
      {
         char* cmd[] = {"say", NULL, "-r", NULL,  NULL};
         cmd[1]      = (char*) speak_text;
         cmd[3]      = speeds[speed-1];
         execvp("say",cmd);
      }
   }
   return true;
}

#endif

static bool frontend_darwin_is_narrator_running(void)
{
#if !TARGET_OS_OSX || (MAC_OS_X_VERSION_MAX_ALLOWED >= 101400)
   if (apple_runtime_available(APPLE_RUNTIME_VER(10, 14, 0), APPLE_RUNTIME_VER(7, 0, 0), APPLE_RUNTIME_VER(9, 0, 0)))
      return true;
#endif
#if TARGET_OS_OSX
   return is_narrator_running_macos();
#else
   return false;
#endif
}

static bool frontend_darwin_accessibility_speak(int speed,
      const char* speak_text, int priority)
{
   if (speed < 1)
      speed               = 1;
   else if (speed > 10)
      speed               = 10;

#if !TARGET_OS_OSX || (MAC_OS_X_VERSION_MAX_ALLOWED >= 101400)
   if (apple_runtime_available(APPLE_RUNTIME_VER(10, 14, 0), APPLE_RUNTIME_VER(7, 0, 0), APPLE_RUNTIME_VER(9, 0, 0)))
   {
      static dispatch_once_t once;
      static AVSpeechSynthesizer *synth;
      dispatch_once(&once, ^{
         synth = [[AVSpeechSynthesizer alloc] init];
      });
      if ([synth isSpeaking])
      {
         if (priority < 10)
            return true;
         else
            [synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
      }

      AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:[NSString stringWithUTF8String:speak_text]];
      if (!utterance)
         return false;
      utterance.rate = (float)speed / 10.0f;
      const char *language = get_user_language_iso639_1(false);
      utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:[NSString stringWithUTF8String:language]];
      [synth speakUtterance:utterance];
      return true;
   }
#endif

#if TARGET_OS_OSX
   return accessibility_speak_macos(speed, speak_text, priority);
#else
   return false;
#endif
}

static void frontend_darwin_content_loaded(void)
{
#ifdef HAVE_SWIFT
   if (apple_runtime_available(APPLE_RUNTIME_VER(13, 0, 0), APPLE_RUNTIME_VER(16, 0, 0), APPLE_RUNTIME_VER(16, 0, 0))) {
      [RetroArchAppShortcuts contentLoaded];
   }
#endif
}

static enum rarch_display_type frontend_darwin_get_display_type(void)
{
   return RARCH_DISPLAY_OSX;
}

frontend_ctx_driver_t frontend_ctx_darwin = {
   frontend_darwin_get_env,         /* get_env */
   NULL,                            /* init */
   NULL,                            /* deinit */
   NULL,                            /* exitspawn */
   NULL,                            /* process_args */
   NULL,                            /* exec */
   NULL,                            /* set_fork */
   NULL,                            /* shutdown */
   frontend_darwin_get_name,        /* get_name */
   frontend_darwin_get_os,          /* get_os               */
   frontend_darwin_content_loaded,  /* content_loaded       */
   frontend_darwin_get_arch,        /* get_architecture     */
   frontend_darwin_get_powerstate,  /* get_powerstate       */
   frontend_darwin_parse_drive_list,/* parse_drive_list     */
   NULL,                            /* install_signal_handler */
   NULL,                            /* get_sighandler_state */
   NULL,                            /* set_sighandler_state */
   NULL,                            /* destroy_signal_handler_state */
   NULL,                            /* attach_console */
   NULL,                            /* detach_console */
   NULL,                            /* get_lakka_version */
   NULL,                            /* set_screen_brightness */
   NULL,                            /* set_sustained_performance_mode */
   frontend_darwin_get_cpu_model_name, /* get_cpu_model_name */
   frontend_darwin_get_user_language, /* get_user_language   */
   frontend_darwin_is_narrator_running, /* is_narrator_running */
   frontend_darwin_accessibility_speak, /* accessibility_speak */
   NULL,                            /* set_gamemode        */
   frontend_darwin_get_display_type,
   "darwin",                        /* ident               */
   NULL                             /* get_video_driver    */
};
