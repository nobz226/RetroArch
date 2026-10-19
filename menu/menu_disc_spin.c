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
#include "../gfx/video_driver.h"
#include "../gfx/gfx_surface.h"
#include "../verbosity.h"

#if defined(__APPLE__)
#include "../ui/drivers/cocoa/cocoa_menu_extras.h"
#endif

/* The disc spins this long before the launch: from standstill to full
 * speed over DISC_SPIN_ACCEL_USEC, then at full speed */
#define DISC_SPIN_UP_USEC        2500000
#define DISC_SPIN_ACCEL_USEC     1500000
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

   /* Where the disc is in its picture (0..1, from the top left): a
    * scan is rarely centred, square or quite round */
   float disc_u0, disc_v0, disc_u1, disc_v1;

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
   bool handover;        /* layer up, menu no longer draws the disc */
   unsigned handover_frames;

   /* The disc alone, shrunk to the size it is drawn at */
   uintptr_t texture;
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

/* The disc's box in its picture. Scans carry the odd stray line of
 * pixels outside the disc, which a plain bounding box would take in, so:
 * the disc's centre is the centre of its solid pixels (a stray line is
 * too light to move it), and each edge is where, walking in from the
 * picture's border along the lines through that centre, at least four
 * pixels in a row are not see-through (a stray line is one or two
 * thick). The threshold is low so a disc's faint clear rim counts. */
#define DISC_SPIN_SOLID   40
#define DISC_SPIN_VISIBLE 8
#define DISC_SPIN_RUN     4
static int disc_spin_walk(const uint32_t *px, int count, int step)
{
   int i, run = 0;
   for (i = 0; i < count; i++)
   {
      if ((px[(size_t)i * step] >> 24) > DISC_SPIN_VISIBLE)
      {
         if (++run >= DISC_SPIN_RUN)
            return i - (DISC_SPIN_RUN - 1);
      }
      else
         run = 0;
   }
   return -1;
}

static void disc_spin_make_texture(const struct texture_image *img,
      unsigned size);
static void disc_spin_free_texture(void);

static void disc_spin_find_disc(const char *path)
{
   struct texture_image img;

   /* Whole picture, just inside its edge, if it can't be read */
   disc_spin_st.disc_u0 = 0.005f;
   disc_spin_st.disc_v0 = 0.005f;
   disc_spin_st.disc_u1 = 0.995f;
   disc_spin_st.disc_v1 = 0.995f;

   disc_spin_free_texture();
   memset(&img, 0, sizeof(img));
   /* The video driver's pixel order: the disc is uploaded from these */
   img.supports_rgba = gfx_surface_wants_rgba();
   if (!image_texture_load(&img, path))
      return;
   if (img.pixels && img.width > 16 && img.height > 16)
   {
      /* The alpha byte is the high byte of the word in either order */
      int w = (int)img.width, h = (int)img.height;
      uint64_t sx = 0, sy = 0, n = 0;
      int x, y;
      for (y = 0; y < h; y++)
      {
         const uint32_t *row = img.pixels + (size_t)y * w;
         for (x = 0; x < w; x++)
            if ((row[x] >> 24) > DISC_SPIN_SOLID)
            {
               sx += x;
               sy += y;
               n++;
            }
      }
      if (n > 0)
      {
         int cx = (int)(sx / n), cy = (int)(sy / n);
         const uint32_t *row = img.pixels + (size_t)cy * w;
         const uint32_t *col = img.pixels + cx;
         int l = disc_spin_walk(row, w, 1);
         int r = disc_spin_walk(row + (w - 1), w, -1);
         int t = disc_spin_walk(col, h, w);
         int b = disc_spin_walk(col + (size_t)(h - 1) * w, h, -w);
         if (l >= 0 && r >= 0 && t >= 0 && b >= 0)
         {
            int x0 = l, x1 = w - r, y0 = t, y1 = h - b;
            /* A disc, not a sliver: most of the picture, around the centre */
            if (     x1 - x0 > w / 2 && y1 - y0 > h / 2
                  && x0 < cx && cx < x1 && y0 < cy && cy < y1)
            {
               disc_spin_st.disc_u0 = (float)x0 / (float)w;
               disc_spin_st.disc_v0 = (float)y0 / (float)h;
               disc_spin_st.disc_u1 = (float)x1 / (float)w;
               disc_spin_st.disc_v1 = (float)y1 / (float)h;
            }
         }
      }
   }
   if (img.pixels)
   {
      /* Drawn at the disc's on-screen size, in whole pixels */
      float dw = (disc_spin_st.disc_u1 - disc_spin_st.disc_u0) * disc_spin_st.icon_w;
      float dh = (disc_spin_st.disc_v1 - disc_spin_st.disc_v0) * disc_spin_st.icon_h;
      disc_spin_make_texture(&img, (unsigned)((dw > dh ? dw : dh) + 0.5f));
   }
   image_texture_free(&img);
}

/* The disc's box of the picture, area-averaged down to @size x @size
 * (weighted by alpha, so see-through pixels don't darken its edge) and
 * handed to the video driver. A scan several times the size it is drawn
 * at, sampled straight down while it turns, shimmers in moving patterns
 * where the disc has fine detail. */
static void disc_spin_make_texture(const struct texture_image *img,
      unsigned size)
{
   struct texture_image small;
   int w  = (int)img->width, h = (int)img->height;
   int x0 = (int)(disc_spin_st.disc_u0 * w), y0 = (int)(disc_spin_st.disc_v0 * h);
   int x1 = (int)(disc_spin_st.disc_u1 * w), y1 = (int)(disc_spin_st.disc_v1 * h);
   unsigned dx, dy;

   if (size < 8 || x1 - x0 < 8 || y1 - y0 < 8)
      return;
   memset(&small, 0, sizeof(small));
   small.width         = size;
   small.height        = size;
   small.supports_rgba = img->supports_rgba;
   if (!(small.pixels = (uint32_t*)malloc(sizeof(uint32_t) * size * size)))
      return;

   for (dy = 0; dy < size; dy++)
   {
      int sy0 = y0 + (int)((int64_t)(y1 - y0) * dy / size);
      int sy1 = y0 + (int)((int64_t)(y1 - y0) * (dy + 1) / size);
      if (sy1 <= sy0)
         sy1 = sy0 + 1;
      for (dx = 0; dx < size; dx++)
      {
         int sx0 = x0 + (int)((int64_t)(x1 - x0) * dx / size);
         int sx1 = x0 + (int)((int64_t)(x1 - x0) * (dx + 1) / size);
         uint64_t c0 = 0, c1 = 0, c2 = 0, ca = 0, n = 0;
         int sx, sy;
         uint32_t out = 0;
         if (sx1 <= sx0)
            sx1 = sx0 + 1;
         for (sy = sy0; sy < sy1 && sy < h; sy++)
         {
            const uint32_t *row = img->pixels + (size_t)sy * w;
            for (sx = sx0; sx < sx1 && sx < w; sx++)
            {
               uint32_t px = row[sx];
               uint32_t a  = px >> 24;
               c0 += (uint64_t)( px        & 0xff) * a;
               c1 += (uint64_t)((px >>  8) & 0xff) * a;
               c2 += (uint64_t)((px >> 16) & 0xff) * a;
               ca += a;
               n++;
            }
         }
         if (n && ca)
            out = (uint32_t)(c0 / ca)
                | (uint32_t)(c1 / ca) <<  8
                | (uint32_t)(c2 / ca) << 16
                | (uint32_t)((ca + n / 2) / n) << 24;
         small.pixels[(size_t)dy * size + dx] = out;
      }
   }

   video_driver_texture_load(&small, TEXTURE_FILTER_LINEAR,
         &disc_spin_st.texture);
   free(small.pixels);
}

static void disc_spin_free_texture(void)
{
   if (disc_spin_st.texture)
      video_driver_texture_unload(&disc_spin_st.texture);
   disc_spin_st.texture = 0;
}

uintptr_t menu_disc_spin_texture(void)
{
   return disc_spin_st.spinning ? disc_spin_st.texture : 0;
}

void menu_disc_spin_disc_box(float *u0, float *v0, float *u1, float *v1)
{
   *u0 = disc_spin_st.disc_u0;
   *v0 = disc_spin_st.disc_v0;
   *u1 = disc_spin_st.disc_u1;
   *v1 = disc_spin_st.disc_v1;
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

   disc_spin_find_disc(disc_spin_st.icon_path);

   disc_spin_st.launch      = launch;
   strlcpy(disc_spin_st.path,  path  ? path  : "", sizeof(disc_spin_st.path));
   strlcpy(disc_spin_st.label, label ? label : "", sizeof(disc_spin_st.label));
   disc_spin_st.type        = type;
   disc_spin_st.idx         = idx;
   disc_spin_st.entry_idx   = entry_idx;
   disc_spin_st.start_usec  = cpu_features_get_time_usec();
   disc_spin_st.handover    = false;
   disc_spin_st.spinning    = true;
   return true;
}

bool menu_disc_spin_active(void)
{
   return disc_spin_st.spinning;
}

bool menu_disc_spin_handed_over(void)
{
   return disc_spin_st.spinning && disc_spin_st.handover;
}

float menu_disc_spin_angle(retro_time_t now)
{
   float t, up;
   if (!disc_spin_st.spinning)
      return 0.0f;
   t  = (float)(now - disc_spin_st.start_usec) / 1000000.0f;
   up = (float)DISC_SPIN_ACCEL_USEC / 1000000.0f;
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
   /* Keep it turning while the load blocks the menu. The layer takes
    * over first and the menu stops drawing the disc under it - where
    * the disc is see-through (the clear ring, soft edges) the menu's
    * last frame would show a still copy behind the turning one - and
    * the launch waits until a frame without it is on screen. */
   if (disc_spin_st.handover)
   {
      if (++disc_spin_st.handover_frames < 3)
         return true;
   }
   else if (disc_spin_st.icon_valid)
   {
      /* Just the disc, from its box in the picture */
      float u0 = disc_spin_st.disc_u0, v0 = disc_spin_st.disc_v0;
      float u1 = disc_spin_st.disc_u1, v1 = disc_spin_st.disc_v1;
      cocoa_disc_spin_overlay_show(disc_spin_st.icon_path,
            u0, v0, u1, v1,
            disc_spin_st.icon_x + u0 * disc_spin_st.icon_w,
            disc_spin_st.icon_y + v0 * disc_spin_st.icon_h,
            (u1 - u0) * disc_spin_st.icon_w,
            (v1 - v0) * disc_spin_st.icon_h,
            disc_spin_st.video_width, disc_spin_st.video_height,
            menu_disc_spin_angle(now), DISC_SPIN_FULL_SPEED);
      disc_spin_st.overlay         = true;
      disc_spin_st.handover        = true;
      disc_spin_st.handover_frames = 0;
      return true;
   }
#endif

   /* The load may rebuild the video driver, and the menu is not
    * drawing the disc any more: let it go now */
   disc_spin_free_texture();
   launch                     = disc_spin_st.launch;
   disc_spin_st.core_frames   = 0;
   disc_spin_st.launching     = true;
   ret = launch(disc_spin_st.path, disc_spin_st.label,
         disc_spin_st.type, disc_spin_st.idx, disc_spin_st.entry_idx);
   disc_spin_st.launching     = false;
   disc_spin_st.spinning      = false;
   disc_spin_st.handover      = false;
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
