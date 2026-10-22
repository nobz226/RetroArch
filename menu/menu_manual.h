/*  RetroArch - A frontend for libretro.
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

/* Game manuals: <thumbnails>/<system>/Named_Manuals/<game>.pdf (plus
 * "<game> (anything).pdf" extras), read full screen on top of the
 * menu - from a game's Run list, or from the Quick Menu while it
 * plays. Pages are drawn by the platform's PDF renderer on a task
 * thread and shown as textures; the last page read is remembered per
 * manual. */

#ifndef __MENU_MANUAL_H
#define __MENU_MANUAL_H

#include <boolean.h>
#include <retro_common_api.h>

#include "menu_defines.h"
#include "../gfx/video_driver.h"

RETRO_BEGIN_DECLS

/* Whether the game the menu is showing (the selected playlist entry,
 * or the running content in the Quick Menu) has a manual */
bool menu_manual_available(void);

/* Opens the viewer on that game's manual(s) */
bool menu_manual_open(void);

/* The same for strategy guides: <thumbnails>/<system>/Named_Guides/<game>.pdf */
bool menu_guide_available(void);
bool menu_guide_open(void);

bool menu_manual_is_active(void);

/* Closes the viewer and frees its pages (main thread, video context up) */
void menu_manual_close(void);

/* The video context is going away: forget the textures, don't free them */
void menu_manual_context_destroy(void);

/* Every menu action goes here while the viewer is open */
void menu_manual_action(enum menu_action action);

/* Draws the viewer over the menu */
void menu_manual_frame(video_frame_info_t *video_info);

RETRO_END_DECLS

#endif
