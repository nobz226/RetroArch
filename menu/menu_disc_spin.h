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

/* Disc spin-up: when a game from a disc system is started from its
 * Run entry, and the menu shows that game's disc as its icon (Title
 * images), the disc spins up for a moment before the launch, then keeps
 * spinning (a macOS layer) while the content loads, and stops on the
 * game's first frame.
 *
 * The menu driver reports the disc it draws (menu_disc_spin_set_icon)
 * and asks for the angle while spinning; the Run action asks
 * menu_disc_spin_begin to hold the launch; menu_driver_iterate drives
 * menu_disc_spin_iterate, which launches once the spin-up is done. */

#ifndef __MENU_DISC_SPIN_H
#define __MENU_DISC_SPIN_H

#include <stddef.h>
#include <boolean.h>
#include <retro_common_api.h>
#include <libretro.h>

RETRO_BEGIN_DECLS

typedef int (*menu_disc_spin_launch_t)(const char *path,
      const char *label, unsigned type, size_t idx, size_t entry_idx);

/* Called by the menu driver every frame it draws the selected game's
 * icon in the Run menu: the image file and where it lands on screen
 * (top-left origin, in video pixels). */
void menu_disc_spin_set_icon(const char *image_path,
      float x, float y, float w, float h,
      unsigned video_width, unsigned video_height);
/* Called by the menu driver at the start of every frame */
void menu_disc_spin_clear_icon(void);

/* Run pressed: true when the spin-up has started and will call
 * @launch itself (the caller returns), false to launch now. */
bool menu_disc_spin_begin(menu_disc_spin_launch_t launch,
      const char *path, const char *label, unsigned type,
      size_t idx, size_t entry_idx);

/* True from Run until the content has loaded (or failed to) */
bool menu_disc_spin_active(void);

/* True once the macOS layer has taken the disc over: the menu leaves
 * the disc out, so nothing shows behind the layer's see-through parts */
bool menu_disc_spin_handed_over(void);

/* Where the disc is in its picture while it spins: a box from the
 * top left, 0..1 of the picture's width and height. The menu draws
 * that box as a round disc turning about its own centre. */
void menu_disc_spin_disc_box(float *u0, float *v0, float *u1, float *v1);

/* While spinning: the disc alone (its box, see above), shrunk to the
 * size it is drawn at - 0 if there is none, then draw the picture */
uintptr_t menu_disc_spin_texture(void);

/* Current rotation in radians, counter-clockwise */
float menu_disc_spin_angle(retro_time_t now);

/* menu_driver_iterate: true while the spin-up holds the menu (input
 * is ignored meanwhile); launches when it is done. */
bool menu_disc_spin_iterate(retro_time_t now);

/* After every core frame: the spinning layer goes once the game
 * shows its own picture. */
void menu_disc_spin_core_frame(void);

RETRO_END_DECLS

#endif
