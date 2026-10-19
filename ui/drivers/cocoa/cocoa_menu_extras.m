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

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdlib.h>
#include <string.h>

#include <defines/cocoa_defines.h>

#include "cocoa_menu_extras.h"

#ifdef HAVE_COCOA_MENU_EXTRAS

#include "../../../gfx/video_driver.h"
#include "cocoa_common.h"
#include "apple_platform.h"

static CGPDFDocumentRef cocoa_pdf_open(const char *path)
{
   CFURLRef url;
   CGPDFDocumentRef doc;
   if (!path || !*path)
      return NULL;
   url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
         (const UInt8*)path, (CFIndex)strlen(path), false);
   if (!url)
      return NULL;
   doc = CGPDFDocumentCreateWithURL(url);
   CFRelease(url);
   return doc;
}

unsigned cocoa_pdf_page_count(const char *path)
{
   unsigned count       = 0;
   CGPDFDocumentRef doc = cocoa_pdf_open(path);
   if (!doc)
      return 0;
   count = (unsigned)CGPDFDocumentGetNumberOfPages(doc);
   CGPDFDocumentRelease(doc);
   return count;
}

/* The page's box as shown, with its rotation applied */
static CGRect cocoa_pdf_display_box(CGPDFPageRef page)
{
   CGRect box  = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
   int rotate  = CGPDFPageGetRotationAngle(page) % 360;
   if (rotate < 0)
      rotate  += 360;
   if (rotate == 90 || rotate == 270)
      box.size = CGSizeMake(box.size.height, box.size.width);
   return box;
}

bool cocoa_pdf_page_size(const char *path, unsigned page,
      float *width, float *height)
{
   CGPDFPageRef pg;
   CGRect box;
   CGPDFDocumentRef doc = cocoa_pdf_open(path);
   if (!doc)
      return false;
   /* Core Graphics numbers pages from 1 */
   if (!(pg = CGPDFDocumentGetPage(doc, page + 1)))
   {
      CGPDFDocumentRelease(doc);
      return false;
   }
   box     = cocoa_pdf_display_box(pg);
   *width  = (float)box.size.width;
   *height = (float)box.size.height;
   CGPDFDocumentRelease(doc);
   return box.size.width > 0 && box.size.height > 0;
}

uint32_t *cocoa_pdf_render_page(const char *path, unsigned page,
      unsigned width, unsigned height, bool rgba)
{
   CGPDFPageRef pg;
   CGColorSpaceRef cs;
   CGContextRef ctx;
   CGAffineTransform xf;
   uint32_t *pixels     = NULL;
   CGPDFDocumentRef doc = NULL;

   if (width < 1 || height < 1 || width > 16384 || height > 16384)
      return NULL;
   if (!(doc = cocoa_pdf_open(path)))
      return NULL;
   if (!(pg = CGPDFDocumentGetPage(doc, page + 1)))
   {
      CGPDFDocumentRelease(doc);
      return NULL;
   }
   if (!(pixels = (uint32_t*)calloc((size_t)width * height, sizeof(uint32_t))))
   {
      CGPDFDocumentRelease(doc);
      return NULL;
   }

   cs  = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
   ctx = CGBitmapContextCreate(pixels, width, height, 8, width * 4, cs,
         rgba
         ? (kCGImageAlphaPremultipliedLast  | kCGBitmapByteOrder32Big)
         : (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
   CGColorSpaceRelease(cs);
   if (!ctx)
   {
      free(pixels);
      CGPDFDocumentRelease(doc);
      return NULL;
   }

   /* Paper first: scans have no background of their own to cover the
    * transparent bitmap, and text manuals expect white */
   CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
   CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
   CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
   CGContextSetRenderingIntent(ctx, kCGRenderingIntentDefault);

   /* Fit the page (and its /Rotate) into the bitmap. The drawing
    * transform only ever scales down, so scale up by hand for a
    * bitmap larger than the page's size in points. */
   {
      CGRect box   = cocoa_pdf_display_box(pg);
      CGRect dest  = CGRectMake(0, 0, width, height);
      float scale  = 1.0f;
      if (box.size.width > 0 && box.size.height > 0)
      {
         float sx = (float)width  / (float)box.size.width;
         float sy = (float)height / (float)box.size.height;
         scale    = sx < sy ? sx : sy;
      }
      if (scale > 1.0f)
      {
         CGContextScaleCTM(ctx, scale, scale);
         dest = CGRectMake(0, 0, width / scale, height / scale);
      }
      xf = CGPDFPageGetDrawingTransform(pg, kCGPDFCropBox, dest, 0, true);
      CGContextConcatCTM(ctx, xf);
      CGContextClipToRect(ctx, CGPDFPageGetBoxRect(pg, kCGPDFCropBox));
      CGContextDrawPDFPage(ctx, pg);
   }

   CGContextRelease(ctx);
   CGPDFDocumentRelease(doc);
   return pixels;
}

static CALayer *g_disc_spin_layer = nil;

void cocoa_disc_spin_overlay_hide(void)
{
   if (!g_disc_spin_layer)
      return;
   [CATransaction begin];
   [CATransaction setDisableActions:YES];
   [g_disc_spin_layer removeAllAnimations];
   [g_disc_spin_layer removeFromSuperlayer];
   [CATransaction commit];
   [CATransaction flush];
   RARCH_RELEASE(g_disc_spin_layer);
   g_disc_spin_layer = nil;
}

void cocoa_disc_spin_overlay_show(const char *image_path,
      float u0, float v0, float u1, float v1,
      float x, float y, float w, float h,
      unsigned view_w, unsigned view_h,
      float angle, float radians_per_sec)
{
   NSView *view;
   CALayer *host;
   CGImageRef image;
   CGRect bounds;
   BOOL flipped;
   float dir;
   float sx, sy;
   CABasicAnimation *spin;

   cocoa_disc_spin_overlay_hide();

   if (!image_path || !*image_path || view_w < 1 || view_h < 1
         || w < 1 || h < 1 || radians_per_sec <= 0.0f)
      return;
   if (!(view = (NSView*)apple_platform.renderView))
      return;
   if (!(host = view.layer))
      return;

   {
      NSImage *ns_image = [[NSImage alloc] initWithContentsOfFile:
         [NSString stringWithUTF8String:image_path]];
      if (!ns_image)
         return;
      CGImageRef whole = [ns_image CGImageForProposedRect:NULL context:nil hints:nil];
      image            = NULL;
      if (whole)
      {
         /* Just the disc (image space has its origin at the top left) */
         float iw  = (float)CGImageGetWidth(whole);
         float ih  = (float)CGImageGetHeight(whole);
         CGRect cr = CGRectIntegral(CGRectMake(u0 * iw, v0 * ih,
                  (u1 - u0) * iw, (v1 - v0) * ih));
         image     = CGImageCreateWithImageInRect(whole, cr);
         if (!image)
         {
            image = whole;
            CGImageRetain(image);
         }
      }
      RARCH_RELEASE(ns_image);
      if (!image)
         return;
   }

   /* Shrunk to the pixels it covers with a proper filter first: a scan
    * several times that size, sampled straight down while it turns,
    * shimmers in moving patterns where the disc has fine detail */
   {
      size_t pw = (size_t)(w + 0.5f), ph = (size_t)(h + 0.5f);
      CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
      CGContextRef ctx   = (pw > 0 && ph > 0
            && (pw < CGImageGetWidth(image) || ph < CGImageGetHeight(image)))
         ? CGBitmapContextCreate(NULL, pw, ph, 8, 0, cs,
               kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big)
         : NULL;
      CGColorSpaceRelease(cs);
      if (ctx)
      {
         CGImageRef small;
         CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
         CGContextDrawImage(ctx, CGRectMake(0, 0, pw, ph), image);
         if ((small = CGBitmapContextCreateImage(ctx)))
         {
            CGImageRelease(image);
            image = small;
         }
         CGContextRelease(ctx);
      }
   }

   /* Render-view pixels to the layer's points. A layer's origin is at
    * the bottom left unless its geometry is flipped, which also turns
    * a positive rotation clockwise. */
   bounds  = host.bounds;
   sx      = (float)bounds.size.width  / (float)view_w;
   sy      = (float)bounds.size.height / (float)view_h;
   flipped = host.contentsAreFlipped;
   dir     = flipped ? -1.0f : 1.0f;

   [CATransaction begin];
   [CATransaction setDisableActions:YES];
   g_disc_spin_layer                 = [[CALayer alloc] init];
   g_disc_spin_layer.contents        = (__bridge id)image;
   /* Filled, so a slightly oval scan turns as a round disc */
   g_disc_spin_layer.contentsGravity = kCAGravityResize;
   g_disc_spin_layer.minificationFilter = kCAFilterTrilinear;
   g_disc_spin_layer.contentsScale   = view.window
      ? view.window.backingScaleFactor : 1.0;
   g_disc_spin_layer.frame           = CGRectMake(
         x * sx,
         flipped ? y * sy : bounds.size.height - (y + h) * sy,
         w * sx, h * sy);
   g_disc_spin_layer.zPosition       = 1000.0;
   /* Only the round disc turns: a square image's corners would sweep
    * round with it */
   g_disc_spin_layer.cornerRadius    = 0.5 * MIN(w * sx, h * sy);
   g_disc_spin_layer.masksToBounds   = YES;
   [g_disc_spin_layer setValue:@(dir * angle) forKeyPath:@"transform.rotation.z"];
   [host addSublayer:g_disc_spin_layer];

   spin                     = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
   spin.fromValue           = @(dir * angle);
   spin.toValue             = @(dir * (angle + 2.0 * M_PI));
   spin.duration            = (2.0 * M_PI) / radians_per_sec;
   spin.repeatCount         = HUGE_VALF;
   spin.removedOnCompletion = NO;
   [g_disc_spin_layer addAnimation:spin forKey:@"nobz-disc-spin"];
   [CATransaction commit];
   /* Hand it to the window server now: the caller blocks next */
   [CATransaction flush];

   CGImageRelease(image);
}

#endif
