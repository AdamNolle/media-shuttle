#include "app.h"
#include <stdio.h>
#include <string.h>

static void print_usage(const char *prog)
{
    printf("Media Shuttle — Native Linux Edition\n\n");
    printf("Usage:\n");
    printf("  %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  --preview              Run in visual preview / reference mode\n");
    printf("  --screenshot [file]    Render pixel-accurate preview PNG offscreen and exit\n");
    printf("  --theme <dark|light>   Force specific theme\n");
    printf("  --help                 Show this help message\n\n");
    printf("Safety Guarantee:\n");
    printf("  - SHA-256 independent verification on every transferred file\n");
    printf("  - Atomic copy via hidden temporary files\n");
    printf("  - Card erase strictly locked until every remaining file matches destination\n");
}

int main(int argc, char **argv)
{
    if (g_getenv("GSK_RENDERER") == NULL) {
        g_setenv("GSK_RENDERER", "cairo", FALSE);
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
    }

    AppContext *ctx = app_context_new(argc, argv);
    if (ctx == NULL) {
        fprintf(stderr, "Failed to initialize Media Shuttle context\n");
        return 1;
    }

    int ret = app_run(ctx, argc, argv);

    app_context_free(ctx);
    return ret;
}
