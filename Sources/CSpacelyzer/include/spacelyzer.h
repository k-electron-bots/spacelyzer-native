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
int32_t spz_tree_forget(SpzTree *t, uint32_t id);
uint64_t spz_tree_version(const SpzTree *t);
void spz_tree_category_totals(const SpzTree *t, uint64_t *out /* 11 * 2 */);
uint32_t spz_tree_largest_files(const SpzTree *t, uint32_t cap, uint32_t *out);
uint32_t spz_tree_skipped_count(const SpzTree *t);
char *spz_tree_skipped_path(const SpzTree *t, uint32_t i);
uint8_t spz_tree_skipped_reason(const SpzTree *t, uint32_t i);

uint32_t spz_outline_rows(const SpzTree *t, uint32_t root, const uint32_t *expanded, uint32_t n_expanded, SpzRow *out, uint32_t cap);

typedef struct SpzFilterResult SpzFilterResult;
typedef struct {
  uint32_t category_mask; uint8_t has_min; uint8_t has_max; uint8_t has_from; uint8_t has_to;
  uint64_t min_size; uint64_t max_size; int64_t modified_from; int64_t modified_to;
} SpzFilter;
SpzFilterResult *spz_filter_apply(const SpzTree *t, const char *text, const char *ext, SpzFilter f);
void spz_filter_free(SpzFilterResult *h);
uint64_t spz_filter_total_bytes(const SpzFilterResult *h);
uint64_t spz_filter_total_count(const SpzFilterResult *h);
uint64_t spz_filter_size(const SpzFilterResult *h, uint32_t id);
uint32_t spz_filter_largest_files(const SpzTree *t, const SpzFilterResult *h, uint32_t cap, uint32_t *out);
void spz_filter_category_totals(const SpzTree *t, const SpzFilterResult *h, uint64_t *out);
uint32_t spz_filter_count(const SpzFilterResult *h, uint32_t id);
uint32_t spz_outline_rows_sorted(const SpzTree *t, uint32_t root, const uint32_t *expanded, uint32_t n_expanded, const SpzFilterResult *h, uint32_t sort, SpzRow *out, uint32_t cap);
uint32_t spz_outline_rows_filtered(const SpzTree *t, uint32_t root, const uint32_t *expanded, uint32_t n_expanded, const SpzFilterResult *h, SpzRow *out, uint32_t cap);
SpzLayout *spz_layout_new_filtered(const SpzTree *t, uint32_t root, float width, float height, const SpzFilterResult *h);

SpzLayout *spz_layout_new(const SpzTree *t, uint32_t root, float width, float height);
void spz_layout_free(SpzLayout *l);
uint32_t spz_layout_count(const SpzLayout *l);
const SpzRect *spz_layout_rects(const SpzLayout *l);
uint32_t spz_layout_hit(const SpzLayout *l, float x, float y);

void spz_string_free(char *s);

/* Statuses: 0 OK, 1 STALE, 2 MUTATION_FAILED, 3 INVALID, 4 BUSY, 5 INTERNAL. Null results always come with a status. */
SpzFilterResult *spz_filter_apply_status(const SpzTree *t, const char *text, const char *ext, SpzFilter f, int32_t *status);
int32_t spz_filter_status(const SpzTree *t, const SpzFilterResult *h);
SpzLayout *spz_layout_new_status(const SpzTree *t, uint32_t root, float width, float height, const SpzFilterResult *h, int32_t *status);
int32_t spz_layout_status(const SpzTree *t, const SpzLayout *l);

/* Snapshot reads: one engine capture per call. `expected` is a table version the caller already holds, or UINT64_MAX for any.
   `version` receives the version read. A non-OK status writes nothing (counts return 0). */
uint32_t spz_outline_rows_status(const SpzTree *t, uint32_t root, const uint32_t *expanded, uint32_t n_expanded, const SpzFilterResult *h, uint32_t sort, SpzRow *out, uint32_t cap, uint64_t expected, uint64_t *version, int32_t *status);
uint32_t spz_largest_status(const SpzTree *t, const SpzFilterResult *h, uint32_t cap, uint32_t *out, uint64_t expected, uint64_t *version, int32_t *status);
/// Largest folders (directories and packages, never the root, never a removed one) by cumulative size, sizes from the same capture. Unfiltered only.
uint32_t spz_largest_dirs_status(const SpzTree *t, uint32_t cap, uint32_t *out, uint64_t *sizes_out, uint64_t expected, uint64_t *version, int32_t *status);
uint32_t spz_largest_sized_status(const SpzTree *t, const SpzFilterResult *h, uint32_t cap, uint32_t *out, uint64_t *sizes_out, uint64_t expected, uint64_t *version, int32_t *status);
void spz_category_totals_status(const SpzTree *t, const SpzFilterResult *h, uint64_t *out, uint64_t expected, uint64_t *version, int32_t *status);
void spz_tree_node_status(const SpzTree *t, uint32_t id, SpzNode *out, uint64_t expected, uint64_t *version, int32_t *status);

uint64_t spz_filter_version(const SpzFilterResult *h);
uint64_t spz_layout_version(const SpzLayout *l);

typedef struct SpzRowInfo { SpzNode node; uint64_t shown; uint32_t visible_children; } SpzRowInfo;
void spz_row_info_layout(uint64_t *out);
uint32_t spz_outline_snapshot_status(const SpzTree *t, uint32_t root, const uint32_t *expanded, uint32_t n_expanded, const SpzFilterResult *h, uint32_t sort, SpzRow *rows_out, SpzRowInfo *infos_out, uint32_t cap, uint64_t expected, uint64_t *version, uint64_t *root_shown, uint64_t *total_bytes, int32_t *status);
/* Live lstat (never follows a final symlink). Returns 0 ok, >0 OS errno (2 = gone), -1 null argument, -2 caught panic, -3 failure without errno. kind: 0 file, 1 dir, 2 symlink, 3 other. Uncompiled on macOS until a Mac run. */
typedef struct SpzInspect { uint64_t allocated; uint64_t logical; int64_t mtime; uint64_t dev; uint64_t ino; uint32_t nlink; uint8_t kind; uint8_t pad[3]; } SpzInspect;
int32_t spz_inspect_path(const char *path, SpzInspect *out); /* 0 ok, >0 errno, -1 null arg, -2 panic, -3 no errno */
void spz_inspect_layout(uint64_t *out); /* [size, align, off mtime, off dev, off ino, off nlink, off kind]; Swift must compare with MemoryLayout at startup (not written yet) */
typedef struct SpzReview { SpzInspect live; uint8_t live_state; uint8_t pad[7]; } SpzReview;
/* Verdict plus live metadata from ONE lstat. Codes as spz_tree_check_identity; out written only when the return is >= 0. live_state: 0 none, 1 describes the scanned item (Same), 2 describes a DIFFERENT item now at the path (label it so). */
int32_t spz_tree_review(const SpzTree *t, uint32_t id, SpzReview *out);
void spz_review_layout(uint64_t *out); /* [size, align, offset of live_state, offset of live]; the nested SpzInspect is checked with spz_inspect_layout */
int32_t spz_tree_check_identity(const SpzTree *t, uint32_t id); /* 0 same, 1 different, 2 none scanned, 3 lossy name, 4 ancestor symlink, 5 gone; <0 error: -1 arg, -2 panic, -3 no errno, <=-1000 -(1000+errno) */

/* Sticky count of panics caught at any FFI boundary. A legacy call returning 0/null/empty may be a caught-panic fallback; compare before/after a publication. */
uint64_t spz_engine_panic_count(void);

#endif
