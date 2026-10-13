/* RetroArch - A frontend for libretro.
 *
 * "Update Nobz Setup" (Main Menu): downloads what changed in the public
 * setup, github.com/nobz226/retroarch-macos-arm-nobz. Included from
 * platform_darwin.m (TARGET_OS_OSX).
 *
 * The repository's nobz-manifest.json lists every file the updater may
 * install, with its SHA-256: cores, core info, thumbnails, overlays,
 * shaders, cheats, per-core and per-game settings, remaps, the system
 * folder, Dolphin's game settings and shader caches. Files are fetched from
 * the commit the manifest came from, so a push halfway through an update
 * can't mix versions.
 *
 * nobz-update.json in application_data remembers, for each file installed
 * by the updater or the first-run setup, its size, date and the SHA-256 of
 * its repository version. A file whose contents changed since was changed
 * by the user: it stays, and the new version is saved next to it as
 * <name>.new. Dolphin shader caches (*.uidcache) are merged instead, keeping
 * the user's entries and adding new ones. Saves, memory cards, playlists,
 * retroarch.cfg and BIOS files are never written. */

#include <CommonCrypto/CommonDigest.h>
#include <queues/task_queue.h>
#include "../../runloop.h"

static NSString *const ra_upd_repo     = @"nobz226/retroarch-macos-arm-nobz";
static NSString *const ra_upd_branch   = @"main";
static NSString *const ra_upd_manifest = @"nobz-manifest.json";
static NSString *const ra_upd_state    = @"nobz-update.json";
static NSString *const ra_upd_app      = @"Application Support/RetroArch/";
static NSString *const ra_upd_docs     = @"Documents/RetroArch/";
static NSString *const ra_upd_dolphin  = @"Documents/RetroArch/saves/dolphin-emu/User/";

/* Dolphin's pipeline UID cache: "PUID", a version, then fixed-size entries */
#define RA_UPD_UID_HEADER 8
#define RA_UPD_UID_ENTRY  566

static volatile BOOL ra_upd_running = NO;
/* Set at startup; nil in a portable install, which the updater leaves alone */
static NSString *ra_upd_app_data_dir = nil;
static NSString *ra_upd_docs_dir     = nil;

/* Paths the updater may write, relative to the repository's setup folder.
 * The manifest is built with the same rules (tools/export-public.sh); this
 * check keeps a bad manifest from reaching anything else. */
static BOOL ra_upd_allowed(NSString *rel)
{
   static NSArray *app_dirs, *doc_dirs, *never;
   NSString *lower = [rel lowercaseString];
   NSString *name  = [lower lastPathComponent];
   if (!app_dirs)
   {
      app_dirs = @[@"cores/", @"info/", @"thumbnails/", @"overlays/",
                   @"shaders/", @"cht/", @"config/"];
      doc_dirs = @[@"system/", @"cheats/"];
      never    = @[@"/bios/", @"/memcards/", @"/sstates/"];
   }

   if (![rel length] || [rel hasPrefix:@"/"] || [rel hasSuffix:@"/"])
      return NO;
   for (NSString *part in [rel componentsSeparatedByString:@"/"])
      if (![part length] || [part isEqualToString:@".."] || [part isEqualToString:@"."])
         return NO;
   for (NSString *dir in never)
      if ([lower rangeOfString:dir].location != NSNotFound)
         return NO;
   /* Console BIOS and save files, wherever they are */
   if (     [name hasPrefix:@"scph"] || [name isEqualToString:@"ipl.bin"]
         || [name isEqualToString:@"neogeo.zip"] || [name hasPrefix:@"dc_"]
         || [name hasPrefix:@"vmu_save"] || [name isEqualToString:@"playtime.dat"]
         || [name isEqualToString:@"sram.raw"] || [name hasSuffix:@".srm"]
         || [name hasSuffix:@".sav"] || [name hasSuffix:@".mcd"]
         || [name hasSuffix:@".ps2"] || [name hasSuffix:@".gci"])
      return NO;

   if ([rel hasPrefix:ra_upd_app])
   {
      NSString *sub = [rel substringFromIndex:[ra_upd_app length]];
      for (NSString *dir in app_dirs)
         if ([sub hasPrefix:dir])
            /* config/ only below a core's or the remaps' folder: never
             * retroarch.cfg or the keychain */
            return ![dir isEqualToString:@"config/"]
               || [[sub substringFromIndex:[dir length]]
                     rangeOfString:@"/"].location != NSNotFound;
      return NO;
   }
   if ([rel hasPrefix:ra_upd_dolphin])
   {
      NSString *sub = [rel substringFromIndex:[ra_upd_dolphin length]];
      return [sub hasPrefix:@"GameSettings/"]
         || ([sub hasPrefix:@"Cache/"] && [sub hasSuffix:@".uidcache"]
               && [[sub pathComponents] count] == 2);
   }
   if ([rel hasPrefix:ra_upd_docs])
   {
      NSString *sub = [rel substringFromIndex:[ra_upd_docs length]];
      for (NSString *dir in doc_dirs)
         if ([sub hasPrefix:dir])
            return YES;
   }
   return NO;
}

/* Where a repository file lives on this Mac. Dolphin's shared folders are
 * in ~/Documents/RetroArch/shared once profiles are set up. */
static NSString *ra_upd_target(NSString *rel, NSString *app_data, NSString *docs)
{
   if ([rel hasPrefix:ra_upd_dolphin])
   {
      NSString *shared = ra_shared_dolphin_user(docs);
      BOOL dir         = NO;
      if (     [[NSFileManager defaultManager] fileExistsAtPath:shared isDirectory:&dir]
            && dir)
         return [shared stringByAppendingPathComponent:
            [rel substringFromIndex:[ra_upd_dolphin length]]];
   }
   return frontend_darwin_seed_target(rel, app_data, docs);
}

static NSString *ra_upd_hex(const unsigned char *md)
{
   NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
   for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
      [hex appendFormat:@"%02x", md[i]];
   return hex;
}

static NSString *ra_upd_sha_data(NSData *data)
{
   unsigned char md[CC_SHA256_DIGEST_LENGTH];
   CC_SHA256([data bytes], (CC_LONG)[data length], md);
   return ra_upd_hex(md);
}

static NSString *ra_upd_sha_file(NSString *path)
{
   unsigned char md[CC_SHA256_DIGEST_LENGTH];
   CC_SHA256_CTX ctx;
   size_t n;
   unsigned char *buf;
   FILE *f = fopen([path fileSystemRepresentation], "rb");
   if (!f)
      return nil;
   buf = (unsigned char*)malloc(1 << 20);
   CC_SHA256_Init(&ctx);
   while ((n = fread(buf, 1, 1 << 20, f)) > 0)
      CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
   fclose(f);
   free(buf);
   CC_SHA256_Final(md, &ctx);
   return ra_upd_hex(md);
}

/* Files with the home folder written in (seed/home-paths.txt) are stored
 * with "@HOME@" in the repository */
static NSData *ra_upd_home_in(NSData *data)
{
   NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
   return text ? [[text stringByReplacingOccurrencesOfString:@"@HOME@"
      withString:NSHomeDirectory()] dataUsingEncoding:NSUTF8StringEncoding] : data;
}

/* SHA-256 of a local file as the repository would store it */
static NSString *ra_upd_sha_repo_form(NSString *path, BOOL home)
{
   NSData *data;
   NSString *text;
   if (!home)
      return ra_upd_sha_file(path);
   if (!(data = [NSData dataWithContentsOfFile:path]))
      return nil;
   text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
   if (text)
      data = [[text stringByReplacingOccurrencesOfString:NSHomeDirectory()
         withString:@"@HOME@"] dataUsingEncoding:NSUTF8StringEncoding];
   return ra_upd_sha_data(data);
}

static NSDictionary *ra_upd_stat(NSString *path)
{
   struct stat st;
   if (lstat([path fileSystemRepresentation], &st) != 0 || !S_ISREG(st.st_mode))
      return nil;
   return @{ @"size":  @((long long)st.st_size),
             @"mtime": @((double)st.st_mtimespec.tv_sec
                        + st.st_mtimespec.tv_nsec / 1e9) };
}

/* Same size and date as when it was installed */
static BOOL ra_upd_unchanged(NSDictionary *rec, NSDictionary *now)
{
   return rec && now
      && [rec[@"size"] longLongValue] == [now[@"size"] longLongValue]
      && fabs([rec[@"mtime"] doubleValue] - [now[@"mtime"] doubleValue]) < 0.001;
}

static NSData *ra_upd_fetch(NSURLSession *session, NSString *url,
      NSString *accept, NSString **error)
{
   __block NSData *result = nil;
   __block NSString *err  = nil;
   dispatch_semaphore_t sem = dispatch_semaphore_create(0);
   NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
   if (!req.URL)
   {
      if (error)
         *error = @"bad address";
      return nil;
   }
   req.timeoutInterval = 60;
   if (accept)
      [req setValue:accept forHTTPHeaderField:@"Accept"];
   [[session dataTaskWithRequest:req completionHandler:
      ^(NSData *data, NSURLResponse *resp, NSError *e) {
         NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse*)resp statusCode] : 0;
         if (e)
            err = [e localizedDescription];
         else if (code != 200)
            err = [NSString stringWithFormat:@"HTTP %ld", (long)code];
         else
            result = data;
         dispatch_semaphore_signal(sem);
      }] resume];
   dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
   if (error)
      *error = err;
   return result;
}

/* Writes next to the target, then renames over it, so a running reader
 * never sees half a file */
static BOOL ra_upd_write(NSData *data, NSString *path, BOOL executable)
{
   NSString *tmp = [path stringByAppendingString:@".nobz-tmp"];
   [[NSFileManager defaultManager]
      createDirectoryAtPath:[path stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
   if (![data writeToFile:tmp atomically:NO])
      return NO;
   chmod([tmp fileSystemRepresentation], executable ? 0755 : 0644);
   removexattr([tmp fileSystemRepresentation], "com.apple.quarantine", XATTR_NOFOLLOW);
   if (rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]) != 0)
   {
      unlink([tmp fileSystemRepresentation]);
      return NO;
   }
   return YES;
}

/* Local entries first, then the repository's entries the local file lacks.
 * Returns nil when nothing would change. A local file from another Dolphin
 * version (different header) is replaced. */
static NSData *ra_upd_merge_uidcache(NSData *local, NSData *remote)
{
   NSMutableSet *seen;
   NSMutableData *out;
   NSUInteger i, added = 0, n_local, n_remote;
   if (     [remote length] < RA_UPD_UID_HEADER
         || ([remote length] - RA_UPD_UID_HEADER) % RA_UPD_UID_ENTRY)
      return nil;
   if (     !local || [local length] < RA_UPD_UID_HEADER
         || memcmp([local bytes], [remote bytes], RA_UPD_UID_HEADER))
      return remote;

   /* A partial last entry (Dolphin stopped mid-write) is dropped */
   n_local  = ([local length] - RA_UPD_UID_HEADER) / RA_UPD_UID_ENTRY;
   n_remote = ([remote length] - RA_UPD_UID_HEADER) / RA_UPD_UID_ENTRY;
   seen     = [NSMutableSet setWithCapacity:n_local + n_remote];
   out      = [NSMutableData dataWithBytes:[local bytes]
      length:RA_UPD_UID_HEADER + n_local * RA_UPD_UID_ENTRY];
   for (i = 0; i < n_local; i++)
      [seen addObject:[local subdataWithRange:NSMakeRange(
         RA_UPD_UID_HEADER + i * RA_UPD_UID_ENTRY, RA_UPD_UID_ENTRY)]];
   for (i = 0; i < n_remote; i++)
   {
      NSData *e = [remote subdataWithRange:NSMakeRange(
         RA_UPD_UID_HEADER + i * RA_UPD_UID_ENTRY, RA_UPD_UID_ENTRY)];
      if (![seen containsObject:e])
      {
         [seen addObject:e];
         [out appendData:e];
         added++;
      }
   }
   if (!added && [out length] == [local length])
      return nil;
   return out;
}

static NSString *ra_upd_state_path(NSString *app_data)
{
   return [app_data stringByAppendingPathComponent:ra_upd_state];
}

static NSMutableDictionary *ra_upd_state_load(NSString *app_data)
{
   NSData *data = [NSData dataWithContentsOfFile:ra_upd_state_path(app_data)];
   NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data
      options:0 error:nil] : nil;
   NSMutableDictionary *files = [NSMutableDictionary dictionary];
   if ([d isKindOfClass:[NSDictionary class]]
         && [d[@"files"] isKindOfClass:[NSDictionary class]])
      for (NSString *k in d[@"files"])
         if ([d[@"files"][k] isKindOfClass:[NSDictionary class]])
            files[k] = [d[@"files"][k] mutableCopy];
   return files;
}

static void ra_upd_state_save(NSString *app_data, NSDictionary *files, NSString *commit)
{
   NSMutableDictionary *d = [NSMutableDictionary dictionary];
   NSData *data;
   d[@"version"] = @1;
   d[@"files"]   = files;
   if (commit)
      d[@"commit"] = commit;
   data = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];
   if (data)
      [data writeToFile:ra_upd_state_path(app_data) atomically:YES];
}

/* First-run setup: remember what was installed, so the first update can
 * tell the user's changes from files that are simply older */
static void ra_upd_record_seed(NSString *seed, NSString *app_data, NSString *docs)
{
   NSMutableDictionary *files = [NSMutableDictionary dictionary];
   NSDirectoryEnumerator *it  = [[NSFileManager defaultManager] enumeratorAtPath:seed];
   NSString *rel;
   while ((rel = [it nextObject]))
   {
      NSString *to;
      NSDictionary *now;
      if (     [[[it fileAttributes] fileType] isEqualToString:NSFileTypeDirectory]
            || !ra_upd_allowed(rel)
            || !(to = frontend_darwin_seed_target(rel, app_data, docs))
            || !(now = ra_upd_stat(to)))
         continue;
      /* The checksum is filled in by the first update */
      files[rel] = [now mutableCopy];
   }
   ra_upd_state_save(app_data, files, nil);
}

@interface RANobzUpdate : NSObject
@property (atomic, copy)   NSString *title;
@property (atomic, assign) NSUInteger done;
@property (atomic, assign) NSUInteger total;
@property (atomic, assign) BOOL finished;
@property (atomic, assign) BOOL failed;
@property (atomic, assign) BOOL coresChanged;
@end
@implementation RANobzUpdate
@end

/* Updates one file; returns what happened */
enum ra_upd_result
{
   RA_UPD_CURRENT = 0,
   RA_UPD_INSTALLED,
   RA_UPD_KEPT,
   RA_UPD_MERGED,
   RA_UPD_FAILED
};

static enum ra_upd_result ra_upd_one(NSURLSession *session, NSString *base,
      NSString *rel, NSString *sha, BOOL home, NSString *target,
      NSMutableDictionary *files)
{
   NSMutableDictionary *rec;
   NSDictionary *now = ra_upd_stat(target);
   NSString *local_sha, *err = nil;
   NSData *data;
   BOOL cache = [rel hasPrefix:ra_upd_dolphin] && [rel hasSuffix:@".uidcache"];
   BOOL exec  = [rel hasPrefix:[ra_upd_app stringByAppendingString:@"cores/"]];

   @synchronized (files) { rec = files[rel]; }

   if (cache)
   {
      if ([rec[@"sha256"] isEqualToString:sha])
         return RA_UPD_CURRENT;
   }
   else if (now)
   {
      BOOL same = ra_upd_unchanged(rec, now);
      local_sha = (same && rec[@"sha256"]) ? rec[@"sha256"]
         : ra_upd_sha_repo_form(target, home);
      if ([local_sha isEqualToString:sha])
      {
         NSMutableDictionary *r = [now mutableCopy];
         r[@"sha256"] = sha;
         @synchronized (files) { files[rel] = r; }
         return RA_UPD_CURRENT;
      }
      /* Changed since it was installed (or never installed by us): keep it */
      if (!same && !(rec[@"sha256"] && [local_sha isEqualToString:rec[@"sha256"]]))
      {
         if ([rec[@"new"] isEqualToString:sha]
               && [[NSFileManager defaultManager] fileExistsAtPath:
                     [target stringByAppendingString:@".new"]])
            return RA_UPD_CURRENT; /* already reported */
         data = ra_upd_fetch(session, [base stringByAppendingString:
            [rel stringByAddingPercentEncodingWithAllowedCharacters:
               [NSCharacterSet URLPathAllowedCharacterSet]]], nil, &err);
         if (!data || ![ra_upd_sha_data(data) isEqualToString:sha])
            return RA_UPD_FAILED;
         if (!ra_upd_write(home ? ra_upd_home_in(data) : data,
                  [target stringByAppendingString:@".new"], exec))
            return RA_UPD_FAILED;
         @synchronized (files)
         {
            NSMutableDictionary *r = rec ? [rec mutableCopy] : [NSMutableDictionary dictionary];
            r[@"new"] = sha;
            files[rel] = r;
         }
         return RA_UPD_KEPT;
      }
   }

   data = ra_upd_fetch(session, [base stringByAppendingString:
      [rel stringByAddingPercentEncodingWithAllowedCharacters:
         [NSCharacterSet URLPathAllowedCharacterSet]]], nil, &err);
   if (!data || ![ra_upd_sha_data(data) isEqualToString:sha])
   {
      RARCH_WARN("[Nobz Update] %s: %s\n", [rel UTF8String],
            err ? [err UTF8String] : "checksum mismatch");
      return RA_UPD_FAILED;
   }

   if (cache)
   {
      NSData *merged = ra_upd_merge_uidcache(
         [NSData dataWithContentsOfFile:target], data);
      if (merged && !ra_upd_write(merged, target, NO))
         return RA_UPD_FAILED;
      @synchronized (files) { files[rel] = [@{ @"sha256": sha } mutableCopy]; }
      return merged ? RA_UPD_MERGED : RA_UPD_CURRENT;
   }

   if (!ra_upd_write(home ? ra_upd_home_in(data) : data, target, exec))
      return RA_UPD_FAILED;
   if ((now = ra_upd_stat(target)))
   {
      NSMutableDictionary *r = [now mutableCopy];
      r[@"sha256"] = sha;
      @synchronized (files) { files[rel] = r; }
   }
   return RA_UPD_INSTALLED;
}

static void ra_upd_run(RANobzUpdate *u, NSString *app_data, NSString *docs)
{
   NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
   NSURLSession *session;
   NSString *err = nil, *commit, *base;
   NSData *data;
   NSDictionary *manifest, *list;
   NSSet *home;
   NSMutableDictionary *files;
   NSArray *rels;
   NSOperationQueue *queue;
   __block NSUInteger n_installed = 0, n_kept = 0, n_merged = 0, n_failed = 0;
   NSMutableArray *parts;

   cfg.HTTPMaximumConnectionsPerHost = 6;
   cfg.requestCachePolicy            = NSURLRequestReloadIgnoringLocalCacheData;
   session = [NSURLSession sessionWithConfiguration:cfg];

   u.title = @"Nobz Setup: checking for updates...";
   data    = ra_upd_fetch(session, [NSString stringWithFormat:
      @"https://api.github.com/repos/%@/commits/%@", ra_upd_repo, ra_upd_branch],
      @"application/vnd.github.sha", &err);
   commit  = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
   if ([commit length] != 40)
   {
      u.title  = [NSString stringWithFormat:@"Nobz Setup: can't reach GitHub (%@).",
         err ? err : @"no answer"];
      u.failed = YES;
      return;
   }

   data     = ra_upd_fetch(session, [NSString stringWithFormat:
      @"https://raw.githubusercontent.com/%@/%@/%@", ra_upd_repo, commit, ra_upd_manifest],
      nil, &err);
   manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
   list     = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"files"] : nil;
   if (![list isKindOfClass:[NSDictionary class]] || [manifest[@"version"] intValue] != 1)
   {
      u.title  = @"Nobz Setup: the update list couldn't be read. Try again later.";
      u.failed = YES;
      return;
   }
   home  = [NSSet setWithArray:[manifest[@"home"] isKindOfClass:[NSArray class]]
      ? manifest[@"home"] : @[]];
   base  = [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/setup/",
      ra_upd_repo, commit];
   files = ra_upd_state_load(app_data);
   rels  = [[list allKeys] sortedArrayUsingSelector:@selector(compare:)];
   u.total = [rels count];
   u.title = @"Nobz Setup: updating...";

   queue = [NSOperationQueue new];
   queue.maxConcurrentOperationCount = 6;
   for (NSString *rel in rels)
   {
      NSArray *entry = list[rel];
      [queue addOperationWithBlock:^{
         @autoreleasepool
         {
            enum ra_upd_result r = RA_UPD_FAILED;
            NSString *target;
            if (     [entry isKindOfClass:[NSArray class]] && [entry count] >= 1
                  && [entry[0] isKindOfClass:[NSString class]]
                  && ra_upd_allowed(rel)
                  && (target = ra_upd_target(rel, app_data, docs)))
               r = ra_upd_one(session, base, rel, entry[0], [home containsObject:rel],
                     target, files);
            else
               RARCH_WARN("[Nobz Update] Skipped %s.\n", [rel UTF8String]);
            @synchronized (u)
            {
               switch (r)
               {
                  case RA_UPD_INSTALLED: n_installed++; break;
                  case RA_UPD_KEPT:      n_kept++;      break;
                  case RA_UPD_MERGED:    n_merged++;    break;
                  case RA_UPD_FAILED:    n_failed++;    break;
                  default: break;
               }
               if (     r == RA_UPD_INSTALLED
                     && (     [rel hasPrefix:[ra_upd_app stringByAppendingString:@"cores/"]]
                           || [rel hasPrefix:[ra_upd_app stringByAppendingString:@"info/"]]))
                  u.coresChanged = YES;
               u.done = u.done + 1;
            }
         }
      }];
   }
   [queue waitUntilAllOperationsAreFinished];
   [session finishTasksAndInvalidate];
   @synchronized (files) { ra_upd_state_save(app_data, files, commit); }

   parts = [NSMutableArray array];
   if (n_installed)
      [parts addObject:[NSString stringWithFormat:@"%lu file%@ updated",
         (unsigned long)n_installed, n_installed == 1 ? @"" : @"s"]];
   if (n_merged)
      [parts addObject:[NSString stringWithFormat:@"%lu shader cache%@ merged",
         (unsigned long)n_merged, n_merged == 1 ? @"" : @"s"]];
   if (n_kept)
      [parts addObject:[NSString stringWithFormat:
         @"%lu file%@ you changed kept (new version saved as .new)",
         (unsigned long)n_kept, n_kept == 1 ? @"" : @"s"]];
   if (n_failed)
      [parts addObject:[NSString stringWithFormat:@"%lu couldn't be downloaded, try again later",
         (unsigned long)n_failed]];
   u.failed = n_failed > 0;
   u.title  = [parts count]
      ? [@"Nobz Setup: " stringByAppendingString:[parts componentsJoinedByString:@", "]]
      : @"Nobz Setup is up to date.";
   RARCH_LOG("[Nobz Update] %s (commit %s).\n", [u.title UTF8String], [commit UTF8String]);
}

static void ra_upd_task_handler(retro_task_t *task)
{
   RANobzUpdate *u   = (__bridge RANobzUpdate*)task->user_data;
   NSString *title   = u.title;
   NSUInteger total  = u.total;
   NSUInteger done   = u.done;
   const char *cur   = task->title;

   if (u.finished)
      done = total = 1;
   if (title && (!cur || strcmp(cur, [title UTF8String])))
   {
      task_free_title(task);
      task_set_title(task, strdup([title UTF8String]));
   }
   task_set_progress(task, total ? (int8_t)(done * 100 / total) : -1);
   if (u.finished)
   {
      if (u.failed)
         task_set_error(task, strdup([title UTF8String]));
      task_set_flags(task, RETRO_TASK_FLG_FINISHED, true);
   }
}

static void ra_upd_task_done(retro_task_t *task, void *task_data,
      void *user_data, const char *error)
{
   RANobzUpdate *u = (__bridge_transfer RANobzUpdate*)user_data;
   if (u.coresChanged)
      command_event(CMD_EVENT_CORE_INFO_INIT, NULL);
   ra_upd_running = NO;
}

void frontend_darwin_update_nobz_setup(void)
{
   NSString *app  = ra_upd_app_data_dir;
   NSString *docs = ra_upd_docs_dir;
   RANobzUpdate *u;
   retro_task_t *task;

   if (ra_upd_running)
      return;
   if (!app || !docs)
   {
      const char *_msg = "Update Nobz Setup isn't available in a portable install.";
      runloop_msg_queue_push(_msg, strlen(_msg), 1, 180, true, NULL,
            MESSAGE_QUEUE_ICON_DEFAULT, MESSAGE_QUEUE_CATEGORY_WARNING);
      return;
   }
   if (!(task = task_init()))
      return;

   u              = [RANobzUpdate new];
   u.title        = @"Nobz Setup: checking for updates...";
   task->handler  = ra_upd_task_handler;
   task->callback = ra_upd_task_done;
   task->title    = strdup([u.title UTF8String]);
   task->progress = -1;
   task->user_data = (__bridge_retained void*)u;
   ra_upd_running = YES;

   dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      @autoreleasepool { ra_upd_run(u, app, docs); }
      u.finished = YES;
   });
   task_queue_push(task);
}
