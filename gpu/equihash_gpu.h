/* Kernel ABI for the Zcash/Equihash Wagner solver.
 *
 * This header is the contract between the Zig host (stratum, jobs,
 * verifier, solution packing) and the Wagner-table kernels. Every
 * function here has a CPU reference implementation in
 * equihash_cpu_ref.c; the same signatures will be implemented as CUDA /
 * OpenCL device kernels in Unit 5. Rules for all functions:
 *
 *  - Flat caller-owned buffers, never allocate, never do I/O.
 *  - Row layout: hash[hash_bytes] || idx[idx_bytes], packed, with
 *    `stride` bytes pitch (stride >= hash_bytes + idx_bytes).
 *  - `order`/`scratch` are n-element u32 caller buffers for sorting.
 *  - Pure and deterministic: same inputs give byte-identical outputs,
 *    so CPU references and device kernels are interchangeable.
 */
#ifndef EQUIHASH_GPU_H
#define EQUIHASH_GPU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Row geometry for one Wagner round. The host derives every field from
 * (n, k) exactly as src/equihash.zig Params does; kernels trust it. */
typedef struct eq_geom {
    uint32_t n, k;            /* Equihash params, e.g. 200, 9 */
    uint32_t hash_bytes;      /* current expanded-hash length */
    uint32_t idx_bytes;       /* current index-list length */
    uint32_t prefix_bytes;    /* grouping key length this round */
    uint32_t trim_bytes;      /* hash bytes dropped after xor */
    uint32_t index_unit;      /* 1 = truncated bytes, 4 = full u32 BE */
    uint32_t filter_mode;     /* 0 = exact distinct-index check,
                                 1 = truncated rounds (drop zero-xor
                                     fully-paired dups),
                                 2 = final round (drop fully-paired dups) */
} eq_geom_t;

/* Generate round-0 truncated rows for indices [first, first+count).
 * Each row: expanded Blake2b chunk || truncated index byte, using the
 * Zcash personalization ("ZcashPoW" || le32(n) || le32(k)).
 * Returns rows written (== count for valid geometry). */
size_t eq_gen_rows(const uint8_t input[140], const eq_geom_t *g,
                   uint32_t first, uint32_t count,
                   uint8_t *out, size_t row_stride);

/* Stable LSD radix sort of order[0..n] by row prefix bytes [0..prefix_len).
 * scratch is an n-u32 caller buffer. Afterwards order[] is sorted. */
void eq_sort_order(const uint8_t *rows, size_t row_stride,
                   uint32_t *order, uint32_t *scratch, size_t n,
                   size_t prefix_len);

/* Gather-permute rows into the given order. tmp_row holds one row_stride;
 * visited holds n bytes of scratch (cycle tracking). */
void eq_permute_rows(uint8_t *rows, size_t row_stride,
                     const uint32_t *order, size_t n,
                     uint8_t *tmp_row, uint8_t *visited);

/* Bucket boundaries over sorted rows: bounds[0]=0 < ... < bounds[nb]=n
 * where each bucket shares the first sort byte. bounds_out needs n+1
 * entries. Returns nb (bucket count). */
size_t eq_find_buckets(const uint8_t *rows, size_t row_stride, size_t n,
                       size_t *bounds_out);

/* Count pairs eq_combine_bucket would emit for bucket [blo, bhi). */
size_t eq_count_pairs(const uint8_t *rows, size_t row_stride,
                      const eq_geom_t *g, size_t blo, size_t bhi);

/* Combine colliding pairs within bucket [blo, bhi), appending combined
 * rows to out (capacity out_cap_rows). Returns pairs found; if that
 * exceeds out_cap_rows, writing stops at the cap so the overshoot is
 * visible. Call eq_count_pairs first to size the buffer. */
size_t eq_combine_bucket(const uint8_t *rows, size_t row_stride,
                         const eq_geom_t *g, size_t blo, size_t bhi,
                         uint8_t *out, size_t out_stride,
                         size_t out_cap_rows);

#ifdef __cplusplus
}
#endif

#endif /* EQUIHASH_GPU_H */
