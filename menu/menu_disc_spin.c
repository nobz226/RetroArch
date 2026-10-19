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

#include <math.h>
#include <string.h>
#include <stdlib.h>

#include <compat/strl.h>
#include <file/file_path.h>
#include <lists/dir_list.h>
#include <lists/string_list.h>
#include <formats/image.h>
#include <string/stdstring.h>
#include <features/features_cpu.h>

#include "menu_disc_spin.h"
#include "../configuration.h"
#include "../retroarch.h"
#include "../verbosity.h"

#if defined(__APPLE__)
#include "../ui/drivers/cocoa/cocoa_menu_extras.h"
#endif

/* Spin-up: from standstill to full speed in this long, then the launch */
#define DISC_SPIN_UP_USEC        650000
/* Full speed: two turns a second (a literal drive speed would only
 * look still or flicker) */
#define DISC_SPIN_FULL_SPEED     (2.0f * 2.0f * (float)M_PI)
/* Images looked at to decide whether a system's title images are discs */
#define DISC_SPIN_SAMPLE_IMAGES  6
#define DISC_SPIN_CACHE_SIZE     16

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

struct disc_spin_system
{
   char dir[PATH_MAX_LENGTH];
   bool disc;
};

static struct
{
   /* What the menu drew last frame */
   char icon_path[PATH_MAX_LENGTH];
   float icon_x, icon_y, icon_w, icon_h;
   unsigned video_width, video_height;
   bool icon_valid;

   /* The held launch */
   menu_disc_spin_launch_t launch;
   char path[PATH_MAX_LENGTH];
   char label[PATH_MAX_LENGTH];
   unsigned type;
   size_t idx, entry_idx;

   retro_time_t start_usec;
   unsigned core_frames;
   bool spinning;        /* menu spin-up */
   bool overlay;         /* macOS layer up while loading */
   bool launching;       /* inside launch(): don't hold it again */

   struct disc_spin_system systems[DISC_SPIN_CACHE_SIZE];
   unsigned systems_next;
} disc_spin_st;

void menu_disc_spin_clear_icon(void)
{
   disc_spin_st.icon_valid = false;
}

void menu_disc_spin_set_icon(const char *image_path,
      float x, float y, float w, float h,
      unsigned video_width, unsigned video_height)
{
   if (!image_path || !*image_path || w < 1.0f || h < 1.0f)
      return;
   strlcpy(disc_spin_st.icon_path, image_path, sizeof(disc_spin_st.icon_path));
   disc_spin_st.icon_x       = x;
   disc_spin_st.icon_y       = y;
   disc_spin_st.icon_w       = w;
   disc_spin_st.icon_h       = h;
   disc_spin_st.video_width  = video_width;
   disc_spin_st.video_height = video_height;
   disc_spin_st.icon_valid   = true;
}

/* A disc image: (nearly) square, with see-through corners */
static int disc_spin_image_is_disc(const char *path)
{
   struct texture_image img;
   int result = -1;
   unsigned w, h, i;

   memset(&img, 0, sizeof(img));
   img.supports_rgba = true;
   if (!image_texture_load(&img, path))
      return -1;
   w = img.width;
   h = img.height;
   if (img.pixels && w > 8 && h > 8)
   {
      /* The alpha byte is the high byte of the word in either order */
      const unsigned pts[4][2] = {
         { 2, 2 }, { w - 3, 2 }, { 2, h - 3 }, { w - 3, h - 3 } };
      unsigned clear  = 0;
      float ratio     = (float)w / (float)h;
      for (i = 0; i < 4; i++)
      {
         uint32_t px = img.pixels[pts[i][1] * w + pts[i][0]];
         if ((px >> 24) < 16)
            clear++;
      }
      result = (ratio > 0.97f && ratio < 1.03f && clear >= 3) ? 1 : 0;
   }
   image_texture_free(&img);
   return result;
}

/* Most of the system's title images are discs */
static bool disc_spin_dir_is_disc_system(const char *dir)
{
   unsigned i;
   int discs           = 0;
   int others          = 0;
   struct string_list *list;
   struct disc_spin_system *slot;

   for (i = 0; i < DISC_SPIN_CACHE_SIZE; i++)
      if (string_is_equal(disc_spin_st.systems[i].dir, dir))
         return disc_spin_st.systems[i].disc;

   if ((list = dir_list_new(dir, "png|jpg|jpeg", false, true, false, false)))
   {
      for (i = 0; i < list->size && (discs + others) < DISC_SPIN_SAMPLE_IMAGES; i++)
      {
         int r = disc_spin_image_is_disc(list->elems[i].data);
         if (r == 1)
            discs++;
         else if (r == 0)
            others++;
      }
      string_list_free(list);
   }

   slot = &disc_spin_st.systems[disc_spin_st.systems_next++ % DISC_SPIN_CACHE_SIZE];
   strlcpy(slot->dir, dir, sizeof(slot->dir));
   slot->disc = discs > 0 && discs > others;
   RARCH_LOG("[Disc Spin] \"%s\": %d disc, %d other title image(s) -> %s.\n",
         dir, discs, others, slot->disc ? "disc system" : "no spin");
   return slot->disc;
}

bool menu_disc_spin_begin(menu_disc_spin_launch_t launch,
      const char *path, const char *label, unsigned type,
      size_t idx, size_t entry_idx)
{
   char dir[PATH_MAX_LENGTH];
   settings_t *settings = config_get_ptr();

   if (     disc_spin_st.launching
         || disc_spin_st.spinning
         || !launch
         || !settings
         || !settings->bools.menu_xmb_disc_spin
         || !disc_spin_st.icon_valid)
      return false;

   /* Only Title images are discs: the image's folder is Named_Titles */
   {
      size_t len;
      const char *folder;
      fill_pathname_basedir(dir, disc_spin_st.icon_path, sizeof(dir));
      len = strlen(dir);
      while (len > 1 && (dir[len - 1] == '/' || dir[len - 1] == '\\'))
         dir[--len] = '\0';
      folder = path_basename(dir);
      if (!folder || !string_is_equal(folder, "Named_Titles"))
         return false;
   }
   if (!disc_spin_dir_is_disc_system(dir))
      return false;

   disc_spin_st.launch      = launch;
   strlcpy(disc_spin_st.path,  path  ? path  : "", sizeof(disc_spin_st.path));
   strlcpy(disc_spin_st.label, label ? label : "", sizeof(disc_spin_st.label));
   disc_spin_st.type        = type;
   disc_spin_st.idx         = idx;
   disc_spin_st.entry_idx   = entry_idx;
   disc_spin_st.start_usec  = cpu_features_get_time_usec();
   disc_spin_st.spinning    = true;
   return true;
}

bool menu_disc_spin_active(void)
{
   return disc_spin_st.spinning;
}

float menu_disc_spin_angle(retro_time_t now)
{
   float t, up;
   if (!disc_spin_st.spinning)
      return 0.0f;
   t  = (float)(now - disc_spin_st.start_usec) / 1000000.0f;
   up = (float)DISC_SPIN_UP_USEC / 1000000.0f;
   if (t < 0.0f)
      t = 0.0f;
   /* Even acceleration to full speed, then full speed */
   if (t <= up)
      return 0.5f * (DISC_SPIN_FULL_SPEED / up) * t * t;
   return 0.5f * DISC_SPIN_FULL_SPEED * up + DISC_SPIN_FULL_SPEED * (t - up);
}

static void disc_spin_overlay_hide(void)
{
   if (!disc_spin_st.overlay)
      return;
   disc_spin_st.overlay = false;
#ifdef HAVE_COCOA_MENU_EXTRAS
   cocoa_disc_spin_overlay_hide();
#endif
}

bool menu_disc_spin_iterate(retro_time_t now)
{
   int ret;
   menu_disc_spin_launch_t launch;

   if (!disc_spin_st.spinning)
      return false;
   if (now - disc_spin_st.start_usec < DISC_SPIN_UP_USEC)
      return true;

#ifdef HAVE_COCOA_MENU_EXTRAS
   /* Keep it turning while the load blocks the menu */
   if (disc_spin_st.icon_valid)
   {
      cocoa_disc_spin_overlay_show(disc_spin_st.icon_path,
            disc_spin_st.icon_x, disc_spin_st.icon_y,
            disc_spin_st.icon_w, disc_spin_st.icon_h,
            disc_spin_st.video_width, disc_spin_st.video_height,
            menu_disc_spin_angle(now), DISC_SPIN_FULL_SPEED);
      disc_spin_st.overlay = true;
   }
#endif

   launch                     = disc_spin_st.launch;
   disc_spin_st.core_frames   = 0;
   disc_spin_st.launching     = true;
   ret = launch(disc_spin_st.path, disc_spin_st.label,
         disc_spin_st.type, disc_spin_st.idx, disc_spin_st.entry_idx);
   disc_spin_st.launching     = false;
   disc_spin_st.spinning      = false;
   disc_spin_st.icon_valid    = false;

   /* Nothing loaded (an error, or the core missing): stop here */
   if (ret != 0 || retroarch_ctl(RARCH_CTL_IS_DUMMY_CORE, NULL))
      disc_spin_overlay_hide();
   return true;
}

void menu_disc_spin_core_frame(void)
{
   /* A couple of frames: the first may still be on its way to the
    * screen when it is run */
   if (disc_spin_st.overlay && ++disc_spin_st.core_frames >= 2)
      disc_spin_overlay_hide();
}
