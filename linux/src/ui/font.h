#ifndef MS_FONT_H
#define MS_FONT_H

#include <cairo.h>
#include <pango/pangocairo.h>
#include "theme.h"

typedef enum {
    MS_ALIGN_LEFT = 0,
    MS_ALIGN_CENTER = 1,
    MS_ALIGN_RIGHT = 2
} TextAlign;

typedef enum {
    MS_WEIGHT_REGULAR = PANGO_WEIGHT_NORMAL,
    MS_WEIGHT_MEDIUM = PANGO_WEIGHT_MEDIUM,
    MS_WEIGHT_SEMIBOLD = PANGO_WEIGHT_SEMIBOLD,
    MS_WEIGHT_BOLD = PANGO_WEIGHT_BOLD
} TextWeight;

void font_init(const char *asset_dir);

void font_draw_text(
    cairo_t *cr,
    const char *text,
    double x,
    double y,
    double size_pt,
    TextWeight weight,
    UiColor color,
    double letter_spacing, /* in points / em fraction, e.g. 0.074 */
    double max_width,      /* <= 0 for unlimited */
    TextAlign align);

void font_measure_text(
    cairo_t *cr,
    const char *text,
    double size_pt,
    TextWeight weight,
    double letter_spacing,
    double *out_width,
    double *out_height);

#endif /* MS_FONT_H */
