PKG_CFLAGS := $(shell pkg-config --cflags glib-2.0)
PKG_LIBS := $(shell pkg-config --libs glib-2.0)
UI_CFLAGS := $(shell pkg-config --cflags gtk4 freetype2 fontconfig)
UI_LIBS := $(shell pkg-config --libs gtk4 freetype2 fontconfig)
CFLAGS := -Wall -Wextra -O2 -std=gnu11 $(PKG_CFLAGS)
BUILD := build

CORE_SRCS := $(wildcard src/core/*.c)
CORE_OBJS := $(patsubst src/core/%.c,$(BUILD)/core/%.o,$(CORE_SRCS))
UI_SRCS := $(wildcard src/ui/*.c)
UI_OBJS := $(patsubst src/ui/%.c,$(BUILD)/ui/%.o,$(UI_SRCS))

$(BUILD)/core/%.o: src/core/%.c
	@mkdir -p $(BUILD)/core
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/ui/%.o: src/ui/%.c
	@mkdir -p $(BUILD)/ui
	$(CC) $(CFLAGS) $(UI_CFLAGS) -c $< -o $@

$(BUILD)/media-shuttle: $(CORE_OBJS) $(UI_OBJS)
	$(CC) $^ -o $@ $(PKG_LIBS) $(UI_LIBS) -lm

$(BUILD)/core-tests: $(CORE_OBJS) tests/test_core.o
	$(CC) $^ -o $@ $(PKG_LIBS) -lm

$(BUILD)/render-offscreen: $(CORE_OBJS) $(BUILD)/ui/font.o $(BUILD)/ui/theme.o $(BUILD)/ui/layout.o $(BUILD)/ui/draw.o tools/render_offscreen.o
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(UI_CFLAGS) tools/render_offscreen.o $(BUILD)/core/*.o $(BUILD)/ui/font.o $(BUILD)/ui/theme.o $(BUILD)/ui/layout.o $(BUILD)/ui/draw.o -o $@ $(PKG_LIBS) $(UI_LIBS) -lm

tests/test_core.o: tests/test_core.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

tools/render_offscreen.o: tools/render_offscreen.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(UI_CFLAGS) -c $< -o $@

.PHONY: tests app clean
tests: $(BUILD)/core-tests
app: $(BUILD)/media-shuttle
clean:
	rm -rf $(BUILD)
