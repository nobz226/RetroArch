/* Single-source definitions: tenth main menu action.
 * Grammar identical to settings_def_video_sync.h plus S_FLOAT and
 * the _NS no-sublabel variants; the descriptor argument span
 * matches SDESC_<kind>_ROW; row order is menu display order;
 * h2json.py parses these rows for the Crowdin source upload. */

/* Descriptor and configuration rows are #if !TARGET_OS_IPHONE && !defined(HAVE_LAKKA); the string
 * tables always carry this row via the strings pass. */
#if (!TARGET_OS_IPHONE && !defined(HAVE_LAKKA)) || defined(SETTINGS_DEF_STRINGS_PASS)
S_ACTION_EX(RESTART_RETROARCH,
      "restart_retroarch", SD_FLAG_NONE, NULL, NULL, CMD_EVENT_RESTART_RETROARCH,
      "Switch User",
      "Restart RetroArch and choose who's playing. Each user has their own saves, settings and RetroAchievements account.")
#endif

/* macOS only (frontend/drivers/platform_darwin_update.m) */
#if (defined(__APPLE__) && !TARGET_OS_IPHONE && defined(HAVE_NETWORKING)) || defined(SETTINGS_DEF_STRINGS_PASS)
S_ACTION_EX(UPDATE_NOBZ_SETUP,
      "update_nobz_setup", SD_FLAG_NONE, NULL, NULL, CMD_EVENT_UPDATE_NOBZ_SETUP,
      "Update Nobz Setup",
      "Download new cores, game settings, patches, thumbnails, overlays, shaders and shader caches. Files you changed are kept, and the new version is saved next to them as .new. Saves, memory cards and BIOS files are never touched.")
#endif
