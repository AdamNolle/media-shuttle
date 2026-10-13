#ifndef MS_DRAW_H
#define MS_DRAW_H

#include <cairo.h>
#include "layout.h"
#include "theme.h"

void draw_view(cairo_t *cr, const UiState *state, const char *assets_dir);

#endif /* MS_DRAW_H */
