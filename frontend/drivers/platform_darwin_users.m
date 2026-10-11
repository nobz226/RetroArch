/* RetroArch - A frontend for libretro.
 *
 * macOS user profiles, the startup permissions page and the
 * "Who's playing?" picker. Included from platform_darwin.m (TARGET_OS_OSX).
 *
 * Each user is a folder in ~/Documents/RetroArch/users/<name>:
 *   user.cfg      settings each user keeps (save folders, notifications,
 *                 hardcore mode, volume), merged over retroarch.cfg
 *   keychain.cfg  that user's RetroAchievements login (token only)
 *   avatar.png    their picture, shown in the menu's top-right corner
 *   saves/        every core's saves, PS2 memory cards (saves/PCEE2/memcards)
 *                 and Dolphin's GameCube/Wii saves
 *   states/       savestates
 * "default" is the profile with no owner. Dolphin's settings, game patches
 * and other non-save folders are shared through links to
 * ~/Documents/RetroArch/shared/dolphin-emu/User.
 *
 * RetroArch reads users/<name>/user.cfg and keychain.cfg on top of the
 * shared config (config_set_user_profile_dir); switching users restarts
 * the app, which shows the picker again. */

#import <GameController/GameController.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static NSString *const ra_default_user = @"default";

static NSString *ra_users_root(NSString *docs)
{
   return [docs stringByAppendingPathComponent:@"users"];
}

/* Value of "key = "value"" in a config file's text, or nil */
static NSString *ra_cfg_get(NSString *text, NSString *key)
{
   for (NSString *l in [text componentsSeparatedByString:@"\n"])
   {
      NSRange eq;
      NSString *k, *v;
      if (![l hasPrefix:key])
         continue;
      eq = [l rangeOfString:@"="];
      if (eq.location == NSNotFound)
         continue;
      k = [[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:
         [NSCharacterSet whitespaceCharacterSet]];
      if (![k isEqualToString:key])
         continue;
      v = [[l substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:
         [NSCharacterSet whitespaceCharacterSet]];
      if ([v hasPrefix:@"\""] && [v hasSuffix:@"\""] && [v length] >= 2)
         v = [v substringWithRange:NSMakeRange(1, [v length] - 2)];
      return v;
   }
   return nil;
}

/* A user's folder name from the name they typed; nil when unusable */
static NSString *ra_user_folder_name(NSString *name)
{
   NSString *n = [name stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
   n = [[n componentsSeparatedByCharactersInSet:
      [NSCharacterSet characterSetWithCharactersInString:@"/:\\\"\n\t"]]
      componentsJoinedByString:@"-"];
   while ([n hasPrefix:@"."])
      n = [n substringFromIndex:1];
   if (![n length] || [[n lowercaseString] isEqualToString:ra_default_user])
      return nil;
   if ([n length] > 32)
      n = [n substringToIndex:32];
   return n;
}

static NSString *ra_user_display_name(NSString *folder)
{
   return [folder isEqualToString:ra_default_user] ? @"Default" : folder;
}

/* User folders, owners first (alphabetical), Default last */
static NSArray *ra_users_list(NSString *docs)
{
   NSFileManager *fm   = [NSFileManager defaultManager];
   NSMutableArray *out = [NSMutableArray array];
   NSArray *names      = [[fm contentsOfDirectoryAtPath:ra_users_root(docs) error:nil]
      sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
   BOOL has_default    = NO;
   for (NSString *n in names)
   {
      BOOL dir = NO;
      if ([n hasPrefix:@"."])
         continue;
      if (![fm fileExistsAtPath:[ra_users_root(docs) stringByAppendingPathComponent:n]
            isDirectory:&dir] || !dir)
         continue;
      if ([n isEqualToString:ra_default_user])
         has_default = YES;
      else
         [out addObject:n];
   }
   if (has_default)
      [out addObject:ra_default_user];
   return out;
}

static void ra_write_text(NSString *text, NSString *path, BOOL private_file)
{
   if (![text hasSuffix:@"\n"])
      text = [text stringByAppendingString:@"\n"];
   [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
   if (private_file)
      chmod([path fileSystemRepresentation], 0600);
}

/* Settings a new user starts with: the current values of the keys each
 * user keeps (configuration.c, config_user_profile_keys), paths aside. */
static NSArray *ra_user_pref_keys(void)
{
   return @[@"cheevos_enable", @"cheevos_hardcore_mode_enable",
            @"video_font_enable", @"audio_volume", @"audio_mixer_volume"];
}

/* Creates the user's folder, user.cfg and keychain.cfg where missing.
 * An avatar or a RetroAchievements login given here replaces the old one. */
static void ra_user_create(NSString *docs, NSString *app_data, NSString *folder,
      NSString *avatar_src, NSString *ra_user, NSString *ra_token)
{
   NSFileManager *fm   = [NSFileManager defaultManager];
   NSString *dir       = [ra_users_root(docs) stringByAppendingPathComponent:folder];
   NSString *user_cfg  = [dir stringByAppendingPathComponent:@"user.cfg"];
   NSString *key_cfg   = [dir stringByAppendingPathComponent:@"keychain.cfg"];

   [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"saves"]
      withIntermediateDirectories:YES attributes:nil error:nil];
   [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"states"]
      withIntermediateDirectories:YES attributes:nil error:nil];

   if (![fm fileExistsAtPath:user_cfg])
   {
      NSString *base = [NSString stringWithContentsOfFile:[app_data
         stringByAppendingPathComponent:@"config/retroarch.cfg"]
         encoding:NSUTF8StringEncoding error:nil];
      NSString *text = @"";
      text = ra_seed_cfg_set(text, @"savefile_directory",
            [dir stringByAppendingPathComponent:@"saves"]);
      text = ra_seed_cfg_set(text, @"savestate_directory",
            [dir stringByAppendingPathComponent:@"states"]);
      for (NSString *k in ra_user_pref_keys())
      {
         NSString *v = base ? ra_cfg_get(base, k) : nil;
         if (v)
            text = ra_seed_cfg_set(text, k, v);
      }
      ra_write_text(text, user_cfg, NO);
   }

   if (![fm fileExistsAtPath:key_cfg] || ra_token)
   {
      NSString *text = @"";
      text = ra_seed_cfg_set(text, @"cheevos_username", ra_token ? ra_user : @"");
      text = ra_seed_cfg_set(text, @"cheevos_password", @"");
      text = ra_seed_cfg_set(text, @"cheevos_token",    ra_token ? ra_token : @"");
      ra_write_text(text, key_cfg, YES);
   }

   if (avatar_src && [fm fileExistsAtPath:avatar_src])
      ra_seed_save_avatar(avatar_src, [dir stringByAppendingPathComponent:@"avatar.png"]);
}

static NSString *ra_shared_dolphin_user(NSString *docs)
{
   return [docs stringByAppendingPathComponent:@"shared/dolphin-emu/User"];
}

/* Dolphin keeps everything in one User folder inside the save folder.
 * Saves (GC, Wii) stay per user; everything else - settings, game
 * patches, texture packs - is a link to the shared copy. */
static void ra_user_link_dolphin(NSString *docs, NSString *dir)
{
   NSFileManager *fm = [NSFileManager defaultManager];
   NSString *shared  = ra_shared_dolphin_user(docs);
   NSString *user    = [dir stringByAppendingPathComponent:@"saves/dolphin-emu/User"];
   NSArray *own      = @[@"GC", @"Wii", @"StateSaves"];
   BOOL is_dir       = NO;

   if (![fm fileExistsAtPath:shared isDirectory:&is_dir] || !is_dir)
      return;
   [fm createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:nil];
   for (NSString *item in [fm contentsOfDirectoryAtPath:shared error:nil])
   {
      NSString *target = [user stringByAppendingPathComponent:item];
      if ([own containsObject:item] || [item hasPrefix:@"."])
         continue;
      if ([fm attributesOfItemAtPath:target error:nil])
         continue; /* already there: a link, or the user's own copy */
      /* Relative (users/<name>/saves/dolphin-emu/User -> shared), so the
       * link still works when the folder is copied to another Mac */
      [fm createSymbolicLinkAtPath:target
         withDestinationPath:[@"../../../../../shared/dolphin-emu/User"
            stringByAppendingPathComponent:item] error:nil];
   }
}

static void ra_move_if_present(NSString *from, NSString *to)
{
   NSFileManager *fm = [NSFileManager defaultManager];
   NSDictionary *a   = [fm attributesOfItemAtPath:from error:nil];
   if (!a || [[a fileType] isEqualToString:NSFileTypeSymbolicLink])
      return;
   [fm createDirectoryAtPath:[to stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
   if (![fm fileExistsAtPath:to])
      [fm moveItemAtPath:from toPath:to error:nil];
}

/* Moves the global RetroAchievements login into a user's keychain.cfg and
 * blanks it in retroarch-keychain.cfg, so no other user inherits it. */
static void ra_take_global_login(NSString *docs, NSString *app_data, NSString *folder,
      NSString *avatar_src)
{
   NSString *key_path = [app_data stringByAppendingPathComponent:
      @"config/retroarch-keychain.cfg"];
   NSString *keys     = [NSString stringWithContentsOfFile:key_path
      encoding:NSUTF8StringEncoding error:nil];
   NSString *user     = keys ? ra_cfg_get(keys, @"cheevos_username") : nil;
   NSString *token    = keys ? ra_cfg_get(keys, @"cheevos_token") : nil;
   BOOL has_login     = [user length] && [token length];

   ra_user_create(docs, app_data, folder, avatar_src,
         has_login ? user : nil, has_login ? token : nil);
   if (keys && has_login)
   {
      keys = ra_seed_cfg_set(keys, @"cheevos_username", @"");
      keys = ra_seed_cfg_set(keys, @"cheevos_password", @"");
      keys = ra_seed_cfg_set(keys, @"cheevos_token",    @"");
      ra_write_text(keys, key_path, YES);
   }
}

/* First launch with profiles on a Mac that already has a setup: the
 * existing saves, savestates, PS2 memory cards, RetroAchievements login
 * and picture become the owner's profile (named after the netplay
 * nickname set at first run); Default starts empty. */
static void ra_users_migrate(NSString *docs, NSString *app_data)
{
   NSFileManager *fm  = [NSFileManager defaultManager];
   NSString *cfg      = [NSString stringWithContentsOfFile:[app_data
      stringByAppendingPathComponent:@"config/retroarch.cfg"]
      encoding:NSUTF8StringEncoding error:nil];
   NSString *folder   = ra_user_folder_name(cfg ? ra_cfg_get(cfg, @"netplay_nickname") : nil);
   NSString *dir, *dolphin, *cards, *avatar;

   if (!folder)
      folder = @"Player";
   dir = [ra_users_root(docs) stringByAppendingPathComponent:folder];
   RARCH_LOG("[Users] Moving this Mac's saves into the profile \"%s\".\n", [folder UTF8String]);
   [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

   ra_move_if_present([docs stringByAppendingPathComponent:@"saves"],
         [dir stringByAppendingPathComponent:@"saves"]);
   ra_move_if_present([docs stringByAppendingPathComponent:@"states"],
         [dir stringByAppendingPathComponent:@"states"]);

   /* Dolphin: everything but the saves becomes shared */
   dolphin = [dir stringByAppendingPathComponent:@"saves/dolphin-emu/User"];
   if ([fm fileExistsAtPath:dolphin])
   {
      NSString *shared = ra_shared_dolphin_user(docs);
      [fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:nil];
      for (NSString *item in [fm contentsOfDirectoryAtPath:dolphin error:nil])
      {
         if ([@[@"GC", @"Wii", @"StateSaves"] containsObject:item] || [item hasPrefix:@"."])
            continue;
         ra_move_if_present([dolphin stringByAppendingPathComponent:item],
               [shared stringByAppendingPathComponent:item]);
      }
   }

   /* PS2 memory cards: copied, the originals stay where they were */
   cards = [docs stringByAppendingPathComponent:@"system/pcsx2/memcards"];
   for (NSString *f in [fm contentsOfDirectoryAtPath:cards error:nil])
   {
      NSString *to;
      if (![[[f pathExtension] lowercaseString] isEqualToString:@"ps2"])
         continue;
      to = [dir stringByAppendingPathComponent:
         [@"saves/PCEE2/memcards" stringByAppendingPathComponent:f]];
      [fm createDirectoryAtPath:[to stringByDeletingLastPathComponent]
         withIntermediateDirectories:YES attributes:nil error:nil];
      if (![fm fileExistsAtPath:to])
         [fm copyItemAtPath:[cards stringByAppendingPathComponent:f] toPath:to error:nil];
   }

   avatar = [app_data stringByAppendingPathComponent:@"assets/user/avatar.png"];
   ra_take_global_login(docs, app_data, folder,
         [fm fileExistsAtPath:avatar] ? avatar : nil);
   ra_user_create(docs, app_data, ra_default_user, nil, nil, nil);
   ra_write_text(folder, [ra_users_root(docs) stringByAppendingPathComponent:@".active"], NO);
}

/* Makes sure the profiles exist before the picker shows them */
static void ra_users_prepare(NSString *docs, NSString *app_data, BOOL seeded)
{
   NSFileManager *fm = [NSFileManager defaultManager];
   if (![fm fileExistsAtPath:[app_data stringByAppendingPathComponent:@"config/retroarch.cfg"]])
      return;
   if (![fm fileExistsAtPath:ra_users_root(docs)])
   {
      ra_users_migrate(docs, app_data);
      return;
   }
   if (seeded)
   {
      /* A fresh install that brought profiles along: the person who just
       * went through the setup window gets their own (or their existing) one */
      NSString *cfg    = [NSString stringWithContentsOfFile:[app_data
         stringByAppendingPathComponent:@"config/retroarch.cfg"]
         encoding:NSUTF8StringEncoding error:nil];
      NSString *folder = ra_user_folder_name(cfg ? ra_cfg_get(cfg, @"netplay_nickname") : nil);
      NSString *avatar = [app_data stringByAppendingPathComponent:@"assets/user/avatar.png"];
      if (!folder)
         folder = @"Player";
      ra_take_global_login(docs, app_data, folder,
            [fm fileExistsAtPath:avatar] ? avatar : nil);
      ra_write_text(folder, [ra_users_root(docs) stringByAppendingPathComponent:@".active"], NO);
   }
   if (![fm fileExistsAtPath:[ra_users_root(docs) stringByAppendingPathComponent:ra_default_user]])
      ra_user_create(docs, app_data, ra_default_user, nil, nil, nil);
}

/* Switches RetroArch to a user before the config is read */
static void ra_user_activate(NSString *docs, NSString *app_data, NSString *folder)
{
   NSFileManager *fm   = [NSFileManager defaultManager];
   NSString *dir       = [ra_users_root(docs) stringByAppendingPathComponent:folder];
   NSString *avatar    = [dir stringByAppendingPathComponent:@"avatar.png"];
   NSString *menu_pic  = [app_data stringByAppendingPathComponent:@"assets/user/avatar.png"];

   ra_user_create(docs, app_data, folder, nil, nil, nil);
   ra_user_link_dolphin(docs, dir);
   ra_write_text(folder, [ra_users_root(docs) stringByAppendingPathComponent:@".active"], NO);

   /* The menu shows assets/user/avatar.png, or the placeholder without one */
   [fm removeItemAtPath:menu_pic error:nil];
   if ([fm fileExistsAtPath:avatar])
   {
      [fm createDirectoryAtPath:[menu_pic stringByDeletingLastPathComponent]
         withIntermediateDirectories:YES attributes:nil error:nil];
      [fm copyItemAtPath:avatar toPath:menu_pic error:nil];
   }

   config_set_user_profile_dir([dir UTF8String]);
   RARCH_LOG("[Users] Playing as \"%s\".\n", [folder UTF8String]);
}

/* ---------------------------------------------------------------------
 * Checks a RetroAchievements account with the login request RetroArch
 * itself makes (rcheevos "login2"); the completion gets the token, or an
 * error message. Shared by the setup window and Add User.
 * ------------------------------------------------------------------- */
static void ra_check_login(NSString *user, NSString *pass,
      void (^done)(NSString *name, NSString *token, NSString *error))
{
   NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
      [NSURL URLWithString:@"https://retroachievements.org/dorequest.php"]];
   [req setHTTPMethod:@"POST"];
   [req setTimeoutInterval:20];
   [req setValue:@"RetroArch/1.22.2 (macOS) rcheevos" forHTTPHeaderField:@"User-Agent"];
   [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
   [req setHTTPBody:[[NSString stringWithFormat:@"r=login2&u=%@&p=%@",
      ra_seed_form_escape(user), ra_seed_form_escape(pass)]
      dataUsingEncoding:NSUTF8StringEncoding]];
   [[[NSURLSession sharedSession] dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err)
   {
      NSDictionary *json = nil;
      if (data)
      {
         id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
         if ([obj isKindOfClass:[NSDictionary class]])
            json = obj;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
         if ([[json objectForKey:@"Success"] boolValue]
               && [[json objectForKey:@"Token"] isKindOfClass:[NSString class]])
         {
            id name = [json objectForKey:@"User"];
            done([name isKindOfClass:[NSString class]] ? name : user,
                  [json objectForKey:@"Token"], nil);
         }
         else if (json && [[json objectForKey:@"Error"] isKindOfClass:[NSString class]])
            done(nil, nil, [json objectForKey:@"Error"]);
         else
            done(nil, nil, @"Couldn't reach RetroAchievements. Check the internet connection.");
      });
   }] resume];
}

/* Runs a panel's own little event loop until done() says so, passing the
 * edit shortcuts to the text fields (there is no Edit menu yet) and
 * holding Cmd-Q back. tick, when given, runs about ten times a second. */
static void ra_run_panel(BOOL (^done)(void), void (^tick)(void))
{
   while (!done())
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
         if (tick)
            tick();
      }
   }
}

static NSPanel *ra_make_panel(NSString *title, CGFloat w, CGFloat h)
{
   NSPanel *win = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
   [win setTitle:title];
   [win setLevel:NSFloatingWindowLevel];
   [win setReleasedWhenClosed:NO];
   return win;
}

/* ---------------------------------------------------------------------
 * Permissions page: asks macOS for everything RetroArch uses, once, before
 * RetroArch appears. macOS remembers the answers per signing identity, so
 * builds signed with the same certificate never ask again.
 * ------------------------------------------------------------------- */
@interface RAPermissions : NSObject <CBCentralManagerDelegate>
@property (nonatomic, strong) NSPanel *win;
@property (nonatomic, strong) NSMutableDictionary *status;
@property (nonatomic, strong) id bluetooth;
@property (nonatomic) BOOL finished;
@end

@implementation RAPermissions

static NSArray *ra_permission_rows(void)
{
   return @[
      @[@"mic",     @"Microphone",        @"Games with microphone input (GameCube mic, Wii Speak)."],
      @[@"drives",  @"External drives",   @"Games, saves and BIOS files on drives like extSSD."],
      @[@"docs",    @"Documents folder",  @"Saves, playlists and settings in Documents/RetroArch."],
      @[@"network", @"Local network",     @"Netplay and RetroArch's network commands."],
      @[@"bt",      @"Bluetooth",         @"Real Wii Remotes in Dolphin."],
   ];
}

- (NSTextField *)statusLabel:(NSString *)key
{
   return (NSTextField *)[[self.win contentView] viewWithTag:
      (NSInteger)[[ra_permission_rows() valueForKey:@"firstObject"] indexOfObject:key] + 100];
}

- (void)setState:(NSString *)state for:(NSString *)key
{
   [self.status setObject:state forKey:key];
   [[self statusLabel:key] setStringValue:state];
}

- (void)refresh
{
   if (@available(macOS 10.14, *))
   {
      AVAuthorizationStatus s = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
      [self setState:s == AVAuthorizationStatusAuthorized ? @"Allowed"
         : (s == AVAuthorizationStatusNotDetermined ? @"Not asked yet" : @"Not allowed")
         for:@"mic"];
   }
   if (@available(macOS 10.15, *))
   {
      Class cb = NSClassFromString(@"CBManager");
      if (cb)
      {
         CBManagerAuthorization a = [cb authorization];
         [self setState:a == CBManagerAuthorizationAllowedAlways ? @"Allowed"
            : (a == CBManagerAuthorizationNotDetermined ? @"Not asked yet" : @"Not allowed")
            for:@"bt"];
      }
   }
}

- (void)build
{
   NSView *v;
   NSArray *rows = ra_permission_rows();
   NSUInteger i;
   NSButton *b;
   CGFloat y = 268;

   self.status = [NSMutableDictionary dictionary];
   self.win    = ra_make_panel(@"RetroArch - MacOS-ARM-Nobz Edition", 560, 420);
   v           = [self.win contentView];
   [v addSubview:ra_seed_label(@"Permissions", 16, YES, NSMakeRect(24, 380, 512, 24))];
   [v addSubview:ra_seed_label(@"RetroArch asks for these once, here, so games never stop to ask later. Click Allow All and answer each macOS question.", 12, NO, NSMakeRect(24, 330, 512, 40))];
   for (i = 0; i < [rows count]; i++)
   {
      NSArray *r = [rows objectAtIndex:i];
      NSTextField *s;
      [v addSubview:ra_seed_label([r objectAtIndex:1], 12, YES, NSMakeRect(24, y + 16, 200, 18))];
      [v addSubview:ra_seed_label([r objectAtIndex:2], 11, NO, NSMakeRect(24, y, 360, 16))];
      s = ra_seed_label(@"Not asked yet", 11, NO, NSMakeRect(400, y + 8, 136, 16));
      [s setTextColor:[NSColor secondaryLabelColor]];
      [s setTag:(NSInteger)i + 100];
      [v addSubview:s];
      [self.status setObject:@"Not asked yet" forKey:[r objectAtIndex:0]];
      y -= 44;
   }
   b = [NSButton buttonWithTitle:@"Full Disk Access..." target:self action:@selector(fullDisk:)];
   [b setFrame:NSMakeRect(20, 54, 170, 30)];
   [v addSubview:b];
   [v addSubview:ra_seed_label(@"Optional: one switch that covers every folder and drive.", 11, NO, NSMakeRect(24, 24, 300, 28))];
   b = [NSButton buttonWithTitle:@"Allow All" target:self action:@selector(allowAll:)];
   [b setFrame:NSMakeRect(306, 54, 120, 30)];
   [b setKeyEquivalent:@"\r"];
   [v addSubview:b];
   b = [NSButton buttonWithTitle:@"Continue" target:self action:@selector(done:)];
   [b setFrame:NSMakeRect(432, 54, 110, 30)];
   [v addSubview:b];
   [self refresh];
   [self.win center];
   [NSApp activateIgnoringOtherApps:YES];
   [self.win makeKeyAndOrderFront:nil];
}

/* Reading a folder is what makes macOS ask; done off the main thread,
 * as the read waits for the answer. */
- (void)probeFolder:(NSString *)path key:(NSString *)key
{
   [self setState:@"Asking..." for:key];
   dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      BOOL ok = [[NSFileManager new] contentsOfDirectoryAtPath:path error:nil] != nil;
      dispatch_async(dispatch_get_main_queue(), ^{
         [self setState:ok ? @"Allowed" : @"Not allowed" for:key];
      });
   });
}

- (void)allowAll:(id)sender
{
   NSMutableArray *drives = [NSMutableArray array];
   NSArray *keys = @[NSURLVolumeIsRemovableKey, NSURLVolumeIsInternalKey, NSURLVolumeIsRootFileSystemKey];

   if (@available(macOS 10.14, *))
   {
      if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]
            == AVAuthorizationStatusNotDetermined)
      {
         [self setState:@"Asking..." for:@"mic"];
         [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
         }];
      }
   }

   [self probeFolder:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] key:@"docs"];

   for (NSURL *u in [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys:keys
         options:NSVolumeEnumerationSkipHiddenVolumes])
   {
      NSDictionary *vals = [u resourceValuesForKeys:keys error:nil];
      if ([[vals objectForKey:NSURLVolumeIsRootFileSystemKey] boolValue])
         continue;
      if ([[vals objectForKey:NSURLVolumeIsRemovableKey] boolValue]
            || ![[vals objectForKey:NSURLVolumeIsInternalKey] boolValue])
         [drives addObject:[u path]];
   }
   if ([drives count])
      [self probeFolder:[drives firstObject] key:@"drives"];
   else
      [self setState:@"No drive connected" for:@"drives"];

   /* Any packet to the local network makes macOS ask (macOS 15+) */
   {
      int fd = socket(AF_INET, SOCK_DGRAM, 0);
      if (fd >= 0)
      {
         struct sockaddr_in to;
         memset(&to, 0, sizeof(to));
         to.sin_family = AF_INET;
         to.sin_port   = htons(5353);
         inet_pton(AF_INET, "224.0.0.251", &to.sin_addr);
         sendto(fd, "", 1, 0, (struct sockaddr *)&to, sizeof(to));
         close(fd);
      }
      [self setState:@"Asked" for:@"network"];
   }

   /* Creating a Bluetooth manager is what makes macOS ask */
   if (!self.bluetooth)
   {
      Class cm;
      dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_LAZY);
      cm = NSClassFromString(@"CBCentralManager");
      if (cm)
      {
         [self setState:@"Asking..." for:@"bt"];
         self.bluetooth = [[cm alloc] initWithDelegate:self queue:nil];
      }
   }
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
   [self refresh];
}

- (void)fullDisk:(id)sender
{
   [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
      @"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
}

- (void)done:(id)sender { self.finished = YES; }
@end

static NSString *ra_permissions_flag(void)
{
   return [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Application Support/RetroArch/.permissions-asked"];
}

static void ra_permissions_run_once(void)
{
   RAPermissions *p;
   if ([[NSFileManager defaultManager] fileExistsAtPath:ra_permissions_flag()])
      return;
   p = [RAPermissions new];
   [p build];
   ra_run_panel(^BOOL{ return p.finished; }, nil);
   [p.win orderOut:nil];
   [[NSFileManager defaultManager] createDirectoryAtPath:
      [ra_permissions_flag() stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
   ra_write_text(@"1", ra_permissions_flag(), NO);
}

/* ---------------------------------------------------------------------
 * "Who's playing?" - one tile per user, Default last. Arrows or the
 * gamepad's D-pad/stick move, Return or the gamepad's A/Start plays.
 * ------------------------------------------------------------------- */
@interface RAUserPicker : NSObject
@property (nonatomic, strong) NSPanel *win;
@property (nonatomic, strong) NSView *tiles;
@property (nonatomic, strong) NSArray *users;
@property (nonatomic, strong) NSString *docs;
@property (nonatomic, strong) NSString *appData;
@property (nonatomic, strong) NSString *chosen;
@property (nonatomic) NSInteger selected;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL padLeft, padRight, padGo;
@end

/* Add User panel */
@interface RAAddUser : NSObject
@property (nonatomic, strong) NSPanel *win;
@property (nonatomic, strong) NSTextField *name;
@property (nonatomic, strong) NSImageView *avatar;
@property (nonatomic, strong) NSString *avatarPath;
@property (nonatomic, strong) NSTextField *raUser;
@property (nonatomic, strong) NSSecureTextField *raPass;
@property (nonatomic, strong) NSTextField *error;
@property (nonatomic, strong) NSButton *addButton;
@property (nonatomic, strong) NSString *folder;
@property (nonatomic, strong) NSString *docs;
@property (nonatomic, strong) NSString *appData;
@property (nonatomic) BOOL finished;
@end

@implementation RAAddUser
- (void)buildWithPlaceholder:(NSString *)placeholder
{
   NSView *v;
   NSButton *b;
   self.win = ra_make_panel(@"Add User", 520, 360);
   [self.win setLevel:NSModalPanelWindowLevel];
   v = [self.win contentView];
   [v addSubview:ra_seed_label(@"Add a user", 16, YES, NSMakeRect(24, 320, 472, 24))];
   [v addSubview:ra_seed_label(@"Name", 12, YES, NSMakeRect(24, 284, 200, 18))];
   self.name = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 256, 240, 24)];
   [v addSubview:self.name];
   self.avatar = [[NSImageView alloc] initWithFrame:NSMakeRect(356, 208, 100, 100)];
   [self.avatar setImageScaling:NSImageScaleProportionallyUpOrDown];
   [self.avatar setImage:[[NSImage alloc] initWithContentsOfFile:placeholder]];
   [self.avatar setWantsLayer:YES];
   [[self.avatar layer] setCornerRadius:50];
   [[self.avatar layer] setMasksToBounds:YES];
   [[self.avatar layer] setBackgroundColor:[[NSColor colorWithWhite:0.2 alpha:1.0] CGColor]];
   [v addSubview:self.avatar];
   b = [NSButton buttonWithTitle:@"Choose Picture..." target:self action:@selector(choose:)];
   [b setFrame:NSMakeRect(336, 170, 140, 30)];
   [v addSubview:b];
   [v addSubview:ra_seed_label(@"RetroAchievements (optional)", 12, YES, NSMakeRect(24, 216, 280, 18))];
   [v addSubview:ra_seed_label(@"Username", 11, NO, NSMakeRect(24, 192, 120, 16))];
   self.raUser = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 166, 200, 24)];
   [v addSubview:self.raUser];
   [v addSubview:ra_seed_label(@"Password", 11, NO, NSMakeRect(24, 140, 120, 16))];
   self.raPass = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(24, 114, 200, 24)];
   [v addSubview:self.raPass];
   self.error = ra_seed_label(@"", 11, NO, NSMakeRect(24, 74, 472, 32));
   [self.error setTextColor:[NSColor systemRedColor]];
   [v addSubview:self.error];
   b = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
   [b setFrame:NSMakeRect(290, 24, 100, 30)];
   [v addSubview:b];
   self.addButton = [NSButton buttonWithTitle:@"Add" target:self action:@selector(add:)];
   [self.addButton setFrame:NSMakeRect(398, 24, 100, 30)];
   [self.addButton setKeyEquivalent:@"\r"];
   [v addSubview:self.addButton];
   [self.win center];
   [self.win makeKeyAndOrderFront:nil];
   [self.win makeFirstResponder:self.name];
}

- (void)choose:(id)sender
{
   NSOpenPanel *panel = [NSOpenPanel openPanel];
   NSImage *img;
   [panel setAllowedFileTypes:@[@"png", @"jpg", @"jpeg", @"heic", @"tiff", @"tif", @"gif", @"bmp", @"webp"]];
   [panel setLevel:NSModalPanelWindowLevel + 1];
   if ([panel runModal] != NSModalResponseOK)
      return;
   img = [[NSImage alloc] initWithContentsOfURL:[[panel URLs] firstObject]];
   if (!img)
   {
      [self.error setStringValue:@"That file isn't a picture RetroArch can use."];
      return;
   }
   self.avatarPath = [[[panel URLs] firstObject] path];
   [self.avatar setImage:img];
}

- (void)cancel:(id)sender { self.folder = nil; self.finished = YES; }

- (void)add:(id)sender
{
   NSString *folder = ra_user_folder_name([self.name stringValue]);
   NSString *user   = [self.raUser stringValue];
   NSString *pass   = [self.raPass stringValue];

   if (!folder)
   {
      [self.error setStringValue:@"Enter a name (not \"Default\")."];
      return;
   }
   if ([[NSFileManager defaultManager] fileExistsAtPath:
         [ra_users_root(self.docs) stringByAppendingPathComponent:folder]])
   {
      [self.error setStringValue:@"There is already a user with that name."];
      return;
   }
   if ([user length] != [pass length] && (![user length] || ![pass length]))
   {
      [self.error setStringValue:@"Enter both the RetroAchievements username and password, or neither."];
      return;
   }
   if (![user length])
   {
      ra_user_create(self.docs, self.appData, folder, self.avatarPath, nil, nil);
      self.folder   = folder;
      self.finished = YES;
      return;
   }
   [self.addButton setEnabled:NO];
   [self.error setTextColor:[NSColor secondaryLabelColor]];
   [self.error setStringValue:@"Checking the RetroAchievements account..."];
   ra_check_login(user, pass, ^(NSString *name, NSString *token, NSString *err) {
      [self.addButton setEnabled:YES];
      [self.error setTextColor:[NSColor systemRedColor]];
      if (!token)
      {
         [self.error setStringValue:err];
         return;
      }
      ra_user_create(self.docs, self.appData, folder, self.avatarPath, name, token);
      self.folder   = folder;
      self.finished = YES;
   });
}
@end

@implementation RAUserPicker

static NSImage *ra_round_image(NSString *path, NSString *fallback)
{
   NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
   return img ? img : [[NSImage alloc] initWithContentsOfFile:fallback];
}

- (NSString *)placeholder
{
   return [self.appData stringByAppendingPathComponent:@"assets/user/avatar-placeholder.png"];
}

- (void)layoutTiles
{
   NSUInteger i, n = [self.users count];
   CGFloat tile = 128, gap = 16, width = n * tile + (n ? n - 1 : 0) * gap;
   CGFloat x = MAX(24, ([self.tiles bounds].size.width - width) / 2);

   for (NSView *s in [[self.tiles subviews] copy])
      [s removeFromSuperview];
   for (i = 0; i < n; i++)
   {
      NSString *u = [self.users objectAtIndex:i];
      NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(x + 14, 44, 100, 100)];
      NSTextField *l;
      NSButton *hit;
      [iv setImageScaling:NSImageScaleProportionallyUpOrDown];
      [iv setImage:ra_round_image([[ra_users_root(self.docs) stringByAppendingPathComponent:u]
         stringByAppendingPathComponent:@"avatar.png"], [self placeholder])];
      [iv setWantsLayer:YES];
      [[iv layer] setCornerRadius:50];
      [[iv layer] setMasksToBounds:YES];
      [[iv layer] setBackgroundColor:[[NSColor colorWithWhite:0.2 alpha:1.0] CGColor]];
      [[iv layer] setBorderWidth:(NSInteger)i == self.selected ? 4 : 0];
      [[iv layer] setBorderColor:[[NSColor controlAccentColor] CGColor]];
      [self.tiles addSubview:iv];
      l = ra_seed_label(ra_user_display_name(u), 13, (NSInteger)i == self.selected,
            NSMakeRect(x, 14, tile, 22));
      [l setAlignment:NSTextAlignmentCenter];
      [self.tiles addSubview:l];
      /* a borderless button over the tile: click selects, double-click plays */
      hit = [NSButton buttonWithTitle:@"" target:self action:@selector(tileClicked:)];
      [hit setBordered:NO];
      [hit setTransparent:YES];
      [hit setFrame:NSMakeRect(x, 0, tile, 150)];
      [hit setTag:(NSInteger)i];
      [self.tiles addSubview:hit];
      x += tile + gap;
   }
}

- (void)tileClicked:(NSButton *)sender
{
   NSEvent *ev = [NSApp currentEvent];
   self.selected = [sender tag];
   [self layoutTiles];
   if ([ev clickCount] >= 2)
      [self play:nil];
}

- (void)buildWithDocs:(NSString *)docs appData:(NSString *)app_data
{
   NSView *v;
   NSButton *b;
   NSString *active = [NSString stringWithContentsOfFile:[ra_users_root(docs)
      stringByAppendingPathComponent:@".active"] encoding:NSUTF8StringEncoding error:nil];
   NSUInteger w;

   self.docs     = docs;
   self.appData  = app_data;
   self.users    = ra_users_list(docs);
   active        = [active stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
   self.selected = active ? (NSInteger)[self.users indexOfObject:active] : 0;
   if (self.selected == NSNotFound)
      self.selected = 0;

   w = MAX(560, MIN(1200, [self.users count] * 144 + 64));
   self.win = ra_make_panel(@"RetroArch - MacOS-ARM-Nobz Edition", w, 330);
   v = [self.win contentView];
   [v addSubview:ra_seed_label(@"Who's playing?", 20, YES, NSMakeRect(24, 284, w - 48, 28))];
   self.tiles = [[NSView alloc] initWithFrame:NSMakeRect(0, 80, w, 180)];
   [v addSubview:self.tiles];
   [self layoutTiles];
   [v addSubview:ra_seed_label(@"Arrows or the D-pad choose; Return or A plays.", 11, NO,
         NSMakeRect(24, 28, 320, 16))];
   b = [NSButton buttonWithTitle:@"Add User..." target:self action:@selector(addUser:)];
   [b setFrame:NSMakeRect(w - 248, 22, 120, 30)];
   [v addSubview:b];
   b = [NSButton buttonWithTitle:@"Play" target:self action:@selector(play:)];
   [b setFrame:NSMakeRect(w - 120, 22, 100, 30)];
   [b setKeyEquivalent:@"\r"];
   [v addSubview:b];

   [self.win center];
   [NSApp activateIgnoringOtherApps:YES];
   [self.win makeKeyAndOrderFront:nil];
   /* GameController is loaded on first use */
   dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY);
}

- (void)move:(NSInteger)by
{
   NSInteger n = (NSInteger)[self.users count];
   if (!n)
      return;
   self.selected = (self.selected + by + n) % n;
   [self layoutTiles];
}

- (void)play:(id)sender
{
   if ((NSUInteger)self.selected < [self.users count])
      self.chosen = [self.users objectAtIndex:self.selected];
   self.finished = YES;
}

- (void)addUser:(id)sender
{
   RAAddUser *a = [RAAddUser new];
   a.docs       = self.docs;
   a.appData    = self.appData;
   [a buildWithPlaceholder:[self placeholder]];
   ra_run_panel(^BOOL{ return a.finished; }, nil);
   [a.win orderOut:nil];
   [self.win makeKeyAndOrderFront:nil];
   if (a.folder)
   {
      self.users    = ra_users_list(self.docs);
      self.selected = (NSInteger)[self.users indexOfObject:a.folder];
      if (self.selected == NSNotFound)
         self.selected = 0;
      [self layoutTiles];
   }
}

/* Keyboard and gamepad */
- (void)tick
{
   Class gc = NSClassFromString(@"GCController");
   BOOL left = NO, right = NO, go = NO;
   if (gc)
   {
      for (GCController *c in [gc controllers])
      {
         GCExtendedGamepad *g = [c extendedGamepad];
         if (!g)
            continue;
         left  |= [[[g dpad] left] isPressed]  || [[[g leftThumbstick] xAxis] value] < -0.6f;
         right |= [[[g dpad] right] isPressed] || [[[g leftThumbstick] xAxis] value] >  0.6f;
         go    |= [[g buttonA] isPressed] || [[g buttonB] isPressed];
         if (@available(macOS 10.15, *))
            go |= [[g buttonMenu] isPressed];
      }
   }
   if (left && !self.padLeft)   [self move:-1];
   if (right && !self.padRight) [self move:1];
   if (go && !self.padGo)       [self play:nil];
   self.padLeft = left; self.padRight = right; self.padGo = go;
}
@end

static NSString *ra_user_picker_run(NSString *docs, NSString *app_data)
{
   RAUserPicker *p = [RAUserPicker new];
   id monitor;
   [p buildWithDocs:docs appData:app_data];
   monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
      handler:^NSEvent *(NSEvent *ev) {
         if ([ev window] != p.win)
            return ev;
         switch ([ev keyCode])
         {
            case kVK_LeftArrow:  [p move:-1]; return nil;
            case kVK_RightArrow: [p move:1];  return nil;
            default: break;
         }
         return ev;
      }];
   ra_run_panel(^BOOL{ return p.finished; }, ^{ [p tick]; });
   [NSEvent removeMonitor:monitor];
   [p.win orderOut:nil];
   return p.chosen;
}

/* Everything that happens before RetroArch reads its config */
static void ra_users_startup(NSString *docs, NSString *app_data, BOOL seeded)
{
   NSString *folder = nil;
   NSArray *users;

   ra_permissions_run_once();
   ra_users_prepare(docs, app_data, seeded);
   users = ra_users_list(docs);
   if (![users count])
      return;
   if (getenv("RETROARCH_NO_USER_PICKER"))
      folder = [[NSString stringWithContentsOfFile:[ra_users_root(docs)
         stringByAppendingPathComponent:@".active"] encoding:NSUTF8StringEncoding error:nil]
         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
   else
      folder = ra_user_picker_run(docs, app_data);
   if (![folder length] || ![users containsObject:folder])
      folder = [users firstObject];
   ra_user_activate(docs, app_data, folder);
}

/* Switch User: start a helper that reopens the app once this process has
 * quit (so the config is saved first), then quit. */
static bool frontend_darwin_set_fork(enum frontend_fork fork_mode)
{
   NSString *app, *cmd;
   NSTask *task;
   if (fork_mode != FRONTEND_FORK_RESTART)
      return false;
   app  = [[NSBundle mainBundle] bundlePath];
   cmd  = [NSString stringWithFormat:
      @"while /bin/kill -0 %d 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \"$0\"",
      (int)getpid()];
   task = [NSTask new];
   [task setLaunchPath:@"/bin/sh"];
   [task setArguments:@[@"-c", cmd, app]];
   @try { [task launch]; }
   @catch (NSException *e) { return false; }
   command_event(CMD_EVENT_QUIT, NULL);
   return true;
}
