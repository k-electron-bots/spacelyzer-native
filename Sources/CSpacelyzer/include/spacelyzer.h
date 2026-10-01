#ifndef SPACELYZER_H
#define SPACELYZER_H
#include <stdint.h>

typedef struct SpzScan SpzScan;
typedef struct SpzTree SpzTree;
typedef struct SpzLayout SpzLayout;

typedef struct { uint64_t items; uint64_t bytes; uint8_t finished; uint8_t failed; } SpzProgress;
typedef struct {
  uint64_t size; uint64_t own_bytes; uint32_t parent; uint32_t child_count; uint32_t first_child;
  uint8_t kind; uint8_t category;
} SpzNode;
typedef struct { uint32_t node; uint32_t depth; } SpzRow;
typedef struct {
  float x; float y; float w; float h; uint32_t node; uint32_t depth; uint32_t branch; uint32_t flags; uint64_t size;
} SpzRect;

SpzScan *spz_scan_start(const char *root, const char *excludes);
SpzProgress spz_scan_progress(const SpzScan *s);
void spz_scan_cancel(const SpzScan *s);
SpzTree *spz_scan_take_tree(SpzScan *s);
void spz_scan_free(SpzScan *s);

void spz_tree_free(SpzTree *t);
uint64_t spz_tree_node_count(const SpzTree *t);
uint8_t spz_tree_cancelled(const SpzTree *t);
SpzNode spz_tree_node(const SpzTree *t, uint32_t id);
char *spz_tree_name(const SpzTree *t, uint32_t id);
char *spz_tree_path(const SpzTree *t, uint32_t id);
uint32_t spz_tree_find(const SpzTree *t, const char *path);
void spz_tree_forget(SpzTree *t, uint32_t id);
void spz_tree_category_totals(const SpzTree *t, uint64_t *out /* 11 * 2 */);
uint32_t spz_tree_largest_files(const SpzTree *t, uint32_t cap, uint32_t *out);
uint32_t spz_tree_skipped_count(const SpzTree *t);
char *spz_tree_skipped_path(const SpzTree *t, uint32_t i);
uint8_t spz_tree_skipped_reason(const SpzTree *t, uint32_t i);

uint32_t spz_outline_rows(const SpzTree *t, uint32_t root, const uint32_t *expanded, uint32_t n_expanded, SpzRow *out, uint32_t cap);

SpzLayout *spz_layout_new(const SpzTree *t, uint32_t root, float width, float height);
void spz_layout_free(SpzLayout *l);
uint32_t spz_layout_count(const SpzLayout *l);
const SpzRect *spz_layout_rects(const SpzLayout *l);
uint32_t spz_layout_hit(const SpzLayout *l, float x, float y);

void spz_string_free(char *s);
#endif
