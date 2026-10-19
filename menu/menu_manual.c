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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <compat/strl.h>
#include <file/file_path.h>
#include <file/config_file.h>
#include <lists/dir_list.h>
#include <lists/string_list.h>
#include <queues/task_queue.h>
#include <string/stdstring.h>
#include <retro_miscellaneous.h>

#include "menu_manual.h"
#include "menu_driver.h"
#include "../configuration.h"
#include "../verbosity.h"
#include "../gfx/gfx_display.h"
#include "../gfx/gfx_surface.h"
#include "../gfx/gfx_thumbnail.h"
#include "../gfx/font_driver.h"

#if defined(__APPLE__)
#include "../ui/drivers/cocoa/cocoa_menu_extras.h"
#endif

#define MANUAL_MAX_DOCS      8
#define MANUAL_CACHE_SLOTS   3
#define MANUAL_MAX_TEX_DIM   8192
#define MANUAL_PAGES_FILE    "manual_pages.cfg"

enum manual_zoom
{
   MANUAL_ZOOM_PAGE = 0,  /* whole page on screen */
   MANUAL_ZOOM_WIDTH      /* page as wide as the screen, scrolled */
};

typedef struct
{
   uintptr_t tex;
   unsigned w, h;
   unsigned doc, page, zoom, vw, vh;
   bool used;
} manual_slot_t;

typedef struct
{
   char path[PATH_MAX_LENGTH];
   uint32_t *pixels;
   unsigned doc, page, zoom, vw, vh, w, h;
   unsigned generation;
   bool rgba;
} manual_job_t;

static struct
{
   char docs[MANUAL_MAX_DOCS][PATH_MAX_LENGTH];
   unsigned page_counts[MANUAL_MAX_DOCS];
   char title[NAME_MAX_LENGTH];
   manual_slot_t slots[MANUAL_CACHE_SLOTS];
   /* Requests in flight, so a page isn't asked for twice */
   unsigned pending_page[MANUAL_CACHE_SLOTS];
   unsigned pending_doc[MANUAL_CACHE_SLOTS];
   unsigned pending_zoom[MANUAL_CACHE_SLOTS];
   bool pending[MANUAL_CACHE_SLOTS];
   unsigned doc_count;
   unsigned doc;
   unsigned page;
   unsigned zoom;
   unsigned vw, vh;      /* video size the pages are drawn for */
   unsigned generation;  /* bumped on close: late renders are dropped */
   float scroll;         /* 0 top .. 1 bottom, MANUAL_ZOOM_WIDTH */
   bool active;
} manual_st;

/* Where this system's manuals are, the same folder rules as its artwork */
static bool manual_find_docs(char docs[][PATH_MAX_LENGTH], unsigned max,
      unsigned *count, char *title, size_t title_len)
{
   char dir[PATH_MAX_LENGTH];
   char content_dir[DIR_MAX_LENGTH];
   char base[NAME_MAX_LENGTH];
   char path[PATH_MAX_LENGTH];
   const char *system_name             = NULL;
   const char *imgs[3];
   unsigned i;
   struct menu_state *menu_st          = menu_state_get_ptr();
   settings_t *settings                = config_get_ptr();
   gfx_thumbnail_path_data_t *pd       = menu_st ? menu_st->thumbnail_path_data : NULL;

   *count = 0;
   if (!pd || !settings || !*settings->paths.directory_thumbnails)
      return false;
#ifndef HAVE_COCOA_MENU_EXTRAS
   /* No PDF renderer on this platform */
   return false;
#endif

   if (*pd->content_db_name)
      system_name = pd->content_db_name;
   else if (     string_is_equal(pd->system, "history")
              || string_is_equal(pd->system, "favorites"))
   {
      if (gfx_thumbnail_get_content_dir(pd, content_dir, sizeof(content_dir)) == 0)
         return false;
      system_name = content_dir;
   }
   else if (*pd->system)
      system_name = pd->system;
   if (!system_name || !*system_name)
      return false;

   fill_pathname_join_special(path, settings->paths.directory_thumbnails,
         system_name, sizeof(path));
   fill_pathname_join_special(dir, path, "Named_Manuals", sizeof(dir));
   if (!path_is_directory(dir))
      return false;

   /* The image name of the game, as for its artwork: label first */
   imgs[0] = pd->content_img;
   imgs[1] = pd->content_img_full;
   imgs[2] = pd->content_img_short;
   for (i = 0; i < 3 && *count == 0; i++)
   {
      char *ext;
      if (!imgs[i] || !*imgs[i])
         continue;
      strlcpy(base, imgs[i], sizeof(base));
      if ((ext = (char*)path_get_extension_mutable(base)) && ext > base)
         ext[0] = '\0';  /* drop the dot and extension */
      fill_pathname_join_special(path, dir, base, sizeof(path));
      strlcat(path, ".pdf", sizeof(path));
      if (path_is_valid(path))
      {
         strlcpy(docs[(*count)++], path, PATH_MAX_LENGTH);
         strlcpy(title, base, title_len);
      }
   }
   if (*count == 0)
      return false;

   /* Extras: "<game> (MVS Manual).pdf" and the like */
   {
      struct string_list *list = dir_list_new(dir, "pdf", false, false, false, false);
      if (list)
      {
         char prefix[NAME_MAX_LENGTH];
         size_t prefix_len;
         dir_list_sort(list, true);
         snprintf(prefix, sizeof(prefix), "%s (", title);
         prefix_len = strlen(prefix);
         for (i = 0; i < list->size && *count < max; i++)
         {
            const char *name = path_basename(list->elems[i].data);
            if (name && strncmp(name, prefix, prefix_len) == 0)
               strlcpy(docs[(*count)++], list->elems[i].data, PATH_MAX_LENGTH);
         }
         string_list_free(list);
      }
   }
   return true;
}

bool menu_manual_available(void)
{
   char docs[1][PATH_MAX_LENGTH];
   char title[NAME_MAX_LENGTH];
   unsigned count = 0;
   return manual_find_docs(docs, 1, &count, title, sizeof(title)) && count > 0;
}

bool menu_manual_is_active(void)
{
   return manual_st.active;
}

/* The last page read, per manual, kept next to the menu config */
static void manual_pages_path(char *s, size_t len)
{
   settings_t *settings = config_get_ptr();
   fill_pathname_join_special(s,
         settings ? settings->paths.directory_menu_config : "",
         MANUAL_PAGES_FILE, len);
}

static void manual_page_key(char *s, size_t len, const char *doc)
{
   /* djb2 of the file name: keys can't hold spaces or quotes */
   uint32_t hash     = 5381;
   const char *name  = path_basename(doc);
   while (name && *name)
      hash = ((hash << 5) + hash) + (unsigned char)*name++;
   snprintf(s, len, "manual_page_%08x", (unsigned)hash);
}

static unsigned manual_load_page(const char *doc)
{
   char path[PATH_MAX_LENGTH];
   char key[64];
   int page             = 0;
   config_file_t *conf;
   manual_pages_path(path, sizeof(path));
   if (!(conf = config_file_new(path)))
      return 0;
   manual_page_key(key, sizeof(key), doc);
   config_get_int(conf, key, &page);
   config_file_free(conf);
   return page > 0 ? (unsigned)page : 0;
}

static void manual_save_page(const char *doc, unsigned page)
{
   char path[PATH_MAX_LENGTH];
   char key[64];
   config_file_t *conf;
   manual_pages_path(path, sizeof(path));
   if (!(conf = config_file_new(path)))
      conf = config_file_new_alloc();
   if (!conf)
      return;
   manual_page_key(key, sizeof(key), doc);
   config_set_int(conf, key, (int)page);
   config_file_write(conf, path, true);
   config_file_free(conf);
}

static void manual_free_slots(bool unload)
{
   unsigned i;
   for (i = 0; i < MANUAL_CACHE_SLOTS; i++)
   {
      if (manual_st.slots[i].used && unload && manual_st.slots[i].tex)
         video_driver_texture_unload(&manual_st.slots[i].tex);
      memset(&manual_st.slots[i], 0, sizeof(manual_st.slots[i]));
      manual_st.pending[i] = false;
   }
}

static manual_slot_t *manual_find_slot(unsigned doc, unsigned page)
{
   unsigned i;
   for (i = 0; i < MANUAL_CACHE_SLOTS; i++)
   {
      manual_slot_t *s = &manual_st.slots[i];
      if (     s->used
            && s->doc  == doc
            && s->page == page
            && s->zoom == manual_st.zoom
            && s->vw   == manual_st.vw
            && s->vh   == manual_st.vh)
         return s;
   }
   return NULL;
}

#ifdef HAVE_COCOA_MENU_EXTRAS
static void manual_task_handler(retro_task_t *task)
{
   manual_job_t *job = (manual_job_t*)task->state;
   float pw = 0.0f, ph = 0.0f;

   if (     job
         && !(task->flags & RETRO_TASK_FLG_CANCELLED)
         && cocoa_pdf_page_size(job->path, job->page, &pw, &ph))
   {
      float scale = (float)job->vw / pw;
      float w, h;
      if (job->zoom == MANUAL_ZOOM_PAGE && ((float)job->vh / ph) < scale)
         scale = (float)job->vh / ph;
      w = pw * scale;
      h = ph * scale;
      /* Within what a texture can hold, keeping the shape */
      if (w > MANUAL_MAX_TEX_DIM) { h *= MANUAL_MAX_TEX_DIM / w; w = MANUAL_MAX_TEX_DIM; }
      if (h > MANUAL_MAX_TEX_DIM) { w *= MANUAL_MAX_TEX_DIM / h; h = MANUAL_MAX_TEX_DIM; }
      job->w      = (unsigned)(w + 0.5f);
      job->h      = (unsigned)(h + 0.5f);
      if (job->w > 0 && job->h > 0)
         job->pixels = cocoa_pdf_render_page(job->path, job->page,
               job->w, job->h, job->rgba);
   }

   task_set_data(task, job);
   task->state = NULL;
   task_set_flags(task, RETRO_TASK_FLG_FINISHED, true);
}

static void manual_clear_pending(unsigned doc, unsigned page, unsigned zoom)
{
   unsigned i;
   for (i = 0; i < MANUAL_CACHE_SLOTS; i++)
      if (     manual_st.pending[i]
            && manual_st.pending_doc[i]  == doc
            && manual_st.pending_page[i] == page
            && manual_st.pending_zoom[i] == zoom)
         manual_st.pending[i] = false;
}

static void manual_request(unsigned page);

static void manual_task_callback(retro_task_t *task,
      void *task_data, void *user_data, const char *error)
{
   manual_job_t *job = (manual_job_t*)task_data;
   if (!job)
      return;

   if (job->generation == manual_st.generation && manual_st.active)
   {
      manual_clear_pending(job->doc, job->page, job->zoom);

      if (     job->pixels
            && job->vw == manual_st.vw && job->vh == manual_st.vh)
      {
         struct texture_image img;
         manual_slot_t *slot = NULL;
         unsigned i, far     = 0;
         int worst           = -1;

         /* A free slot, else the one furthest from the page read */
         for (i = 0; i < MANUAL_CACHE_SLOTS; i++)
         {
            int dist;
            if (!manual_st.slots[i].used)
            {
               slot = &manual_st.slots[i];
               break;
            }
            dist = (manual_st.slots[i].doc != manual_st.doc)
               ? 100000
               : abs((int)manual_st.slots[i].page - (int)manual_st.page);
            if (manual_st.slots[i].zoom != manual_st.zoom)
               dist += 50000;
            if (dist > worst)
            {
               worst = dist;
               far   = i;
            }
         }
         if (!slot)
         {
            slot = &manual_st.slots[far];
            if (slot->tex)
               video_driver_texture_unload(&slot->tex);
            memset(slot, 0, sizeof(*slot));
         }

         memset(&img, 0, sizeof(img));
         img.pixels        = job->pixels;
         img.width         = job->w;
         img.height        = job->h;
         img.supports_rgba = job->rgba;
         if (video_driver_texture_load(&img, TEXTURE_FILTER_LINEAR, &slot->tex))
         {
            slot->used = true;
            slot->w    = job->w;
            slot->h    = job->h;
            slot->doc  = job->doc;
            slot->page = job->page;
            slot->zoom = job->zoom;
            slot->vw   = job->vw;
            slot->vh   = job->vh;
         }

         /* The current page is in: draw its neighbours ahead */
         if (job->doc == manual_st.doc && job->page == manual_st.page)
         {
            if (manual_st.page + 1 < manual_st.page_counts[manual_st.doc])
               manual_request(manual_st.page + 1);
            if (manual_st.page > 0)
               manual_request(manual_st.page - 1);
         }
      }
   }

   free(job->pixels);
   free(job);
}

static void manual_request(unsigned page)
{
   unsigned i;
   int free_pending = -1;
   retro_task_t *task;
   manual_job_t *job;

   if (     !manual_st.active
         || manual_st.vw == 0
         || manual_st.vh == 0
         || page >= manual_st.page_counts[manual_st.doc]
         || manual_find_slot(manual_st.doc, page))
      return;
   for (i = 0; i < MANUAL_CACHE_SLOTS; i++)
   {
      if (manual_st.pending[i])
      {
         if (     manual_st.pending_doc[i]  == manual_st.doc
               && manual_st.pending_page[i] == page
               && manual_st.pending_zoom[i] == manual_st.zoom)
            return;
      }
      else if (free_pending < 0)
         free_pending = (int)i;
   }
   if (free_pending < 0)
      return;  /* enough in flight; asked again when one lands */

   if (!(job = (manual_job_t*)calloc(1, sizeof(*job))))
      return;
   if (!(task = task_init()))
   {
      free(job);
      return;
   }
   strlcpy(job->path, manual_st.docs[manual_st.doc], sizeof(job->path));
   job->doc        = manual_st.doc;
   job->page       = page;
   job->zoom       = manual_st.zoom;
   job->vw         = manual_st.vw;
   job->vh         = manual_st.vh;
   job->generation = manual_st.generation;
   job->rgba       = gfx_surface_wants_rgba();

   manual_st.pending[free_pending]      = true;
   manual_st.pending_doc[free_pending]  = job->doc;
   manual_st.pending_page[free_pending] = page;
   manual_st.pending_zoom[free_pending] = job->zoom;

   task->handler   = manual_task_handler;
   task->callback  = manual_task_callback;
   task->state     = job;
   task->flags    |= RETRO_TASK_FLG_MUTE;
   task_queue_push(task);
}
#else
static void manual_request(unsigned page) { (void)page; }
#endif

bool menu_manual_open(void)
{
   unsigned i;
   char docs[MANUAL_MAX_DOCS][PATH_MAX_LENGTH];
   char title[NAME_MAX_LENGTH];
   unsigned count = 0;

   if (!manual_find_docs(docs, MANUAL_MAX_DOCS, &count, title, sizeof(title)))
      return false;

   menu_manual_close();
   for (i = 0; i < count; i++)
   {
      strlcpy(manual_st.docs[i], docs[i], sizeof(manual_st.docs[i]));
#ifdef HAVE_COCOA_MENU_EXTRAS
      manual_st.page_counts[i] = cocoa_pdf_page_count(docs[i]);
#endif
   }
   if (!manual_st.page_counts[0])
   {
      RARCH_ERR("[Manual] Could not read \"%s\".\n", docs[0]);
      return false;
   }
   strlcpy(manual_st.title, title, sizeof(manual_st.title));
   manual_st.doc_count = count;
   manual_st.doc       = 0;
   manual_st.zoom      = MANUAL_ZOOM_PAGE;
   manual_st.scroll    = 0.0f;
   manual_st.page      = manual_load_page(docs[0]);
   if (manual_st.page >= manual_st.page_counts[0])
      manual_st.page   = 0;
   manual_st.active    = true;
   RARCH_LOG("[Manual] Opened \"%s\" (%u page(s), %u manual(s)).\n",
         docs[0], manual_st.page_counts[0], count);
   /* The first page is asked for by the first frame, which knows the
    * screen size */
   return true;
}

void menu_manual_close(void)
{
   if (manual_st.active && manual_st.doc_count)
      manual_save_page(manual_st.docs[manual_st.doc], manual_st.page);
   manual_free_slots(true);
   manual_st.active = false;
   manual_st.generation++;
   manual_st.doc_count = 0;
   memset(manual_st.page_counts, 0, sizeof(manual_st.page_counts));
}

void menu_manual_context_destroy(void)
{
   manual_free_slots(false);
}

static void manual_set_page(unsigned doc, unsigned page, float scroll)
{
   if (doc != manual_st.doc)
   {
      manual_save_page(manual_st.docs[manual_st.doc], manual_st.page);
      manual_st.doc = doc;
      page          = manual_load_page(manual_st.docs[doc]);
   }
   if (page >= manual_st.page_counts[doc])
      page = manual_st.page_counts[doc] ? manual_st.page_counts[doc] - 1 : 0;
   manual_st.page   = page;
   manual_st.scroll = scroll;
   manual_request(page);
}

void menu_manual_action(enum menu_action action)
{
   unsigned page  = manual_st.page;
   unsigned count = manual_st.page_counts[manual_st.doc];
   /* One press of up/down moves a fifth of the screen */
   float step     = 0.2f;

   if (!manual_st.active)
      return;

   if (manual_st.zoom == MANUAL_ZOOM_WIDTH)
   {
      manual_slot_t *s = manual_find_slot(manual_st.doc, page);
      if (s && s->h > manual_st.vh)
         step = 0.2f * (float)manual_st.vh / (float)(s->h - manual_st.vh);
      else
         step = 1.0f;
   }

   switch (action)
   {
      case MENU_ACTION_CANCEL:
      case MENU_ACTION_START:
         menu_manual_close();
         break;
      case MENU_ACTION_LEFT:
         if (page > 0)
            manual_set_page(manual_st.doc, page - 1, 0.0f);
         break;
      case MENU_ACTION_RIGHT:
      case MENU_ACTION_OK:
         if (page + 1 < count)
            manual_set_page(manual_st.doc, page + 1, 0.0f);
         break;
      case MENU_ACTION_SCROLL_UP:
         manual_set_page(manual_st.doc, page > 5 ? page - 5 : 0, 0.0f);
         break;
      case MENU_ACTION_SCROLL_DOWN:
         manual_set_page(manual_st.doc, page + 5, 0.0f);
         break;
      case MENU_ACTION_UP:
      case MENU_ACTION_CYCLE_THUMBNAIL_PRIMARY:
         if (manual_st.zoom == MANUAL_ZOOM_WIDTH)
         {
            if (manual_st.scroll > 0.0f)
               manual_st.scroll = MAX(0.0f, manual_st.scroll - step);
            else if (page > 0)  /* keep reading upwards: previous page's end */
               manual_set_page(manual_st.doc, page - 1, 1.0f);
         }
         else if (manual_st.doc_count > 1)
            manual_set_page((manual_st.doc + manual_st.doc_count - 1)
                  % manual_st.doc_count, 0, 0.0f);
         break;
      case MENU_ACTION_DOWN:
      case MENU_ACTION_CYCLE_THUMBNAIL_SECONDARY:
         if (manual_st.zoom == MANUAL_ZOOM_WIDTH)
         {
            if (manual_st.scroll < 1.0f)
               manual_st.scroll = MIN(1.0f, manual_st.scroll + step);
            else if (page + 1 < count)  /* on to the next page's top */
               manual_set_page(manual_st.doc, page + 1, 0.0f);
         }
         else if (manual_st.doc_count > 1)
            manual_set_page((manual_st.doc + 1) % manual_st.doc_count, 0, 0.0f);
         break;
      case MENU_ACTION_SCAN:
      case MENU_ACTION_SEARCH:
      case MENU_ACTION_INFO:
         manual_st.zoom   = (manual_st.zoom == MANUAL_ZOOM_PAGE)
            ? MANUAL_ZOOM_WIDTH : MANUAL_ZOOM_PAGE;
         manual_st.scroll = 0.0f;
         manual_request(manual_st.page);
         break;
      default:
         break;
   }
}

static void manual_draw_texture(void *userdata, gfx_display_t *p_disp,
      gfx_display_ctx_driver_t *dispctx, unsigned video_width,
      unsigned video_height, uintptr_t tex, float x, float y, float w, float h)
{
   gfx_display_ctx_draw_t draw;
   struct video_coords coords;
   math_matrix_4x4 mymat;
   float white[16] = {
      1.0f, 1.0f, 1.0f, 1.0f,
      1.0f, 1.0f, 1.0f, 1.0f,
      1.0f, 1.0f, 1.0f, 1.0f,
      1.0f, 1.0f, 1.0f, 1.0f
   };

   if (!dispctx || !tex || w < 1.0f || h < 1.0f)
      return;

   gfx_display_blend_begin(dispctx, userdata);
   if (!dispctx->handles_transform)
      gfx_display_rotate_z(p_disp, &mymat, 1.0f, 0.0f, userdata);

   coords.vertices      = 4;
   coords.vertex        = NULL;
   coords.tex_coord     = NULL;
   coords.lut_tex_coord = NULL;
   coords.color         = white;

   draw.scale_factor    = 1.0f;
   draw.rotation        = 0.0f;
   draw.coords          = &coords;
   draw.matrix_data     = &mymat;
   draw.texture         = tex;
   draw.pipeline_id     = 0;
   draw.dims            = VIDEO_SCALE_PACK((unsigned)(w + 0.5f), (unsigned)(h + 0.5f));
   /* Bottom-left origin */
   draw.pos             = VIDEO_POS_PACK(VIDEO_PX(x),
         VIDEO_PX((float)video_height - y - h));
   gfx_display_draw(dispctx, &draw, userdata,
         VIDEO_SCALE_PACK(video_width, video_height));
   gfx_display_blend_end(dispctx, userdata);
}

void menu_manual_frame(video_frame_info_t *video_info)
{
   char msg[NAME_MAX_LENGTH + 256];
   struct font_params params;
   size_t len;
   unsigned video_width, video_height;
   manual_slot_t *slot;
   gfx_display_t *p_disp;
   gfx_display_ctx_driver_t *dispctx;
   float dim[16] = {
      0.0f, 0.0f, 0.0f, 0.94f,
      0.0f, 0.0f, 0.0f, 0.94f,
      0.0f, 0.0f, 0.0f, 0.94f,
      0.0f, 0.0f, 0.0f, 0.94f
   };

   if (!manual_st.active || !video_info)
      return;

   video_width  = VIDEO_SCALE_W(video_info->dims);
   video_height = VIDEO_SCALE_H(video_info->dims);
   p_disp       = disp_get_ptr();
   dispctx      = p_disp ? p_disp->dispctx : NULL;
   if (!dispctx || video_width < 1 || video_height < 1)
      return;

   /* The screen size the pages are drawn for */
   if (video_width != manual_st.vw || video_height != manual_st.vh)
   {
      manual_free_slots(true);
      manual_st.vw = video_width;
      manual_st.vh = video_height;
   }
   if (!(slot = manual_find_slot(manual_st.doc, manual_st.page)))
      manual_request(manual_st.page);

   gfx_display_draw_quad(p_disp, video_info->userdata,
         VIDEO_SCALE_PACK(video_width, video_height),
         0, 0, VIDEO_SCALE_PACK(video_width, video_height),
         VIDEO_SCALE_PACK(video_width, video_height), dim, NULL);

   if (slot)
   {
      float w = (float)slot->w;
      float h = (float)slot->h;
      float x, y;
      if (manual_st.zoom == MANUAL_ZOOM_WIDTH)
      {
         /* As wide as the screen; scrolled when taller */
         h = h * (float)video_width / w;
         w = (float)video_width;
         x = 0.0f;
         y = (h > (float)video_height)
            ? -manual_st.scroll * (h - (float)video_height)
            : ((float)video_height - h) / 2.0f;
      }
      else
      {
         float s = MIN((float)video_width / w, (float)video_height / h);
         w *= s;
         h *= s;
         x  = ((float)video_width  - w) / 2.0f;
         y  = ((float)video_height - h) / 2.0f;
      }
      manual_draw_texture(video_info->userdata, p_disp, dispctx,
            video_width, video_height, slot->tex, x, y, w, h);
   }

   gfx_display_flush_batch(p_disp);

   /* Where we are, and the controls */
   if (manual_st.doc_count > 1)
   {
      const char *name = path_basename(manual_st.docs[manual_st.doc]);
      len = snprintf(msg, sizeof(msg),
            "%s  -  page %u / %u%s   |   Left/Right: page   L/R: 5 pages   Y: zoom   Up/Down: %s   B: close",
            name ? name : manual_st.title,
            manual_st.page + 1, manual_st.page_counts[manual_st.doc],
            slot ? "" : "  (loading)",
            manual_st.zoom == MANUAL_ZOOM_WIDTH ? "scroll" : "other manuals");
   }
   else
      len = snprintf(msg, sizeof(msg),
            "%s  -  page %u / %u%s   |   Left/Right: page   L/R: 5 pages   Y: zoom%s   B: close",
            manual_st.title,
            manual_st.page + 1, manual_st.page_counts[manual_st.doc],
            slot ? "" : "  (loading)",
            manual_st.zoom == MANUAL_ZOOM_WIDTH ? "   Up/Down: scroll" : "");
   if (len >= sizeof(msg))
      len = sizeof(msg) - 1;

   params.x           = 0.01f;
   params.y           = 0.012f;
   params.scale       = 0.85f;
   params.text_align  = TEXT_ALIGN_LEFT;
   params.full_screen = true;
   params.drop_x      = 2;
   params.drop_y      = -2;
   params.drop_mod    = 0.0f;
   params.drop_alpha  = 1.0f;
   params.color       = COLOR_ABGR(255, 255, 255, 255);
   params.color_hp    = NULL;
   font_driver_render_msg(video_info->userdata, msg, len, &params, NULL);
}
