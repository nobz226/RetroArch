/* Single-source definitions: kiosk mode password setting.
 * Grammar identical to settings_def_video_sync.h plus S_FLOAT and
 * the _NS no-sublabel variants; the descriptor argument span
 * matches SDESC_<kind>_ROW; row order is menu display order;
 * h2json.py parses these rows for the Crowdin source upload. */

/* config key "kiosk_mode_password" differs from the label string; the
 * configuration.c row stays literal for this setting. */
#ifndef SETTINGS_DEF_CONFIG_PASS
S_STRING_P(kiosk_mode_password, MENU_KIOSK_MODE_PASSWORD,
      "menu_disable_kiosk_mode_password",
      "", SD_FLAG_ALLOW_INPUT, 0, NULL, NULL, setting_generic_action_start_default, NULL, NULL, NULL, ST_UI_TYPE_PASSWORD_LINE_EDIT,
      "Set Password for Disabling Kiosk Mode",
      "Kiosk mode can be switched off from the Main Menu with Disable Kiosk Mode. With a password set here, Disable Kiosk Mode asks for it first.")
#endif
