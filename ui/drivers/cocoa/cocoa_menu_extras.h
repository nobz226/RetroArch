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

/* macOS helpers for the menu: game manual pages rendered with Core
 * Graphics, and the disc spin-up layer that keeps turning while
 * content loads (the main thread is blocked then, the window server
 * is not). Plain C entry points, implemented in cocoa_menu_extras.m. */

#ifndef __COCOA_MENU_EXTRAS_H
#define __COCOA_MENU_EXTRAS_H

#include <stdint.h>
#include <stddef.h>
#include <boolean.h>
#include <retro_common_api.h>

#if defined(__APPLE__) && !defined(HAVE_COCOATOUCH) \
      && (defined(HAVE_COCOA) || defined(HAVE_COCOA_METAL))
#define HAVE_COCOA_MENU_EXTRAS 1
#endif

RETRO_BEGIN_DECLS

#ifdef HAVE_COCOA_MENU_EXTRAS
/* Number of pages, 0 if the file is not a readable PDF. */
unsigned cocoa_pdf_page_count(const char *path);

/* Size of a page's crop box in points; false if there is no such page. */
bool cocoa_pdf_page_size(const char *path, unsigned page,
      float *width, float *height);

/* Renders page @page (0-based) of @path into a newly malloc'd
 * width * height buffer of 32-bit pixels on a white background:
 * R,G,B,A byte order when @rgba, else B,G,R,A (ARGB words). NULL on
 * failure. Safe on any thread; opens its own document. */
uint32_t *cocoa_pdf_render_page(const char *path, unsigned page,
      unsigned width, unsigned height, bool rgba);

/* Puts @image_path over the render view at the given rectangle (in
 * render-view pixels, top-left origin, of a @view_w x @view_h
 * frame), turned to @angle radians (counter-clockwise) and spinning
 * at @radians_per_sec. Committed at once so it keeps animating while
 * the caller blocks. */
void cocoa_disc_spin_overlay_show(const char *image_path,
      float x, float y, float w, float h,
      unsigned view_w, unsigned view_h,
      float angle, float radians_per_sec);

void cocoa_disc_spin_overlay_hide(void);
#endif

RETRO_END_DECLS

#endif
