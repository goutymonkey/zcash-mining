/* CPU reference implementations of equihash_gpu.h.
 *
 * Straightforward C ports of the Zig logic in src/equihash.zig, used to
 * prove the kernel ABI sufficient: a solve driven through these entry
 * points must verify. Device kernels (Unit 5) implement the same header
 * with the same byte-level semantics.
 */
#include "equihash_gpu.h"
#include "thirdparty/blake2.h"

#include <assert.h>
#include <string.h>

/* ---- Equihash parameter math (mirrors Zig Params) ---- */
static uint32_t c_bit_len(uint32_t n, uint32_t k) { return n / (k + 1); }
static uint32_t c_byte_len(uint32_t n, uint32_t k) { return (c_bit_len(n, k) + 7) / 8; }
static uint32_t hash_len0(uint32_t n, uint32_t k) { return (k + 1) * c_byte_len(n, k); }
static uint32_t ipho(uint32_t n) { return 512 / n; }

/* ---- bit packing (mirrors expandArray, byte_pad = 0) ---- */
static void expand_row(const uint8_t *in, size_t in_len, uint8_t *out, uint32_t bit_len) {
    uint32_t out_width = (bit_len + 7) / 8;
    uint32_t mask = (bit_len == 32) ? 0xFFFFFFFFu : ((1u << bit_len) - 1);
    uint32_t acc_bits = 0, acc_value = 0, j = 0;
    for (size_t b = 0; b < in_len; b++) {
        acc_value = (acc_value << 8) | in[b];
        acc_bits += 8;
        if (acc_bits >= bit_len) {
            acc_bits -= bit_len;
            for (uint32_t x = 0; x < out_width; x++) {
                uint32_t shift = acc_bits + 8 * (out_width - x - 1);
                uint32_t keep = (mask >> (8 * (out_width - x - 1))) & 0xFF;
                out[j + x] = (uint8_t)((acc_value >> shift) & keep);
            }
            j += out_width;
        }
    }
}

static uint8_t trunc_index(uint32_t idx, uint32_t ilen) {
    return (uint8_t)((idx >> (ilen - 8)) & 0xff);
}

/* ---- Blake2b with Zcash personalization (mirrors HashState) ----
 * Returns 0 on success. Explicit status (not assert-only): some build
 * modes compile asserts out, and hashing must never fail silently. */
static int gen_hash(const uint8_t input[140], uint32_t n, uint32_t k,
                    uint32_t g, uint8_t *out, size_t outlen) {
    blake2b_state S;
    blake2b_param P;
    uint8_t pers[16];
    uint8_t le[4];
    memset(&P, 0, sizeof P);
    memcpy(pers, "ZcashPoW", 8);
    pers[8] = (uint8_t)(n & 0xff); pers[9] = (uint8_t)((n >> 8) & 0xff);
    pers[10] = (uint8_t)((n >> 16) & 0xff); pers[11] = (uint8_t)((n >> 24) & 0xff);
    pers[12] = (uint8_t)(k & 0xff); pers[13] = (uint8_t)((k >> 8) & 0xff);
    pers[14] = (uint8_t)((k >> 16) & 0xff); pers[15] = (uint8_t)((k >> 24) & 0xff);
    P.digest_length = (uint8_t)outlen;
    P.fanout = 1;
    P.depth = 1;
    memcpy(P.personal, pers, 16);
    if (blake2b_init_param(&S, &P) != 0) return -1;
    if (blake2b_update(&S, input, 140) != 0) return -1;
    le[0] = (uint8_t)(g & 0xff); le[1] = (uint8_t)((g >> 8) & 0xff);
    le[2] = (uint8_t)((g >> 16) & 0xff); le[3] = (uint8_t)((g >> 24) & 0xff);
    if (blake2b_update(&S, le, 4) != 0) return -1;
    if (blake2b_final(&S, out, outlen) != 0) return -1;
    return 0;
}

size_t eq_gen_rows(const uint8_t input[140], const eq_geom_t *g,
                   uint32_t first, uint32_t count,
                   uint8_t *out, size_t row_stride) {
    uint32_t n = g->n, k = g->k;
    uint32_t per_hash = ipho(n), n8 = n / 8, hout = per_hash * n8;
    uint32_t hl = hash_len0(n, k), cbl = c_bit_len(n, k), ilen = cbl + 1;
    if (g->hash_bytes != hl || g->index_unit != 1) return 0;
    uint8_t h[64];
    if (hout > sizeof h) return 0;
    for (uint32_t t = 0; t < count; t++) {
        uint32_t idx = first + t;
        if (gen_hash(input, n, k, idx / per_hash, h, hout) != 0) return t;
        uint8_t *row = out + (size_t)t * row_stride;
        memset(row, 0, row_stride);
        expand_row(h + (size_t)(idx % per_hash) * n8, n8, row, cbl);
        row[hl] = trunc_index(idx, ilen);
        (void)k;
    }
    return count;
}

/* ---- sorting (mirrors radixSortRows, split in two kernels) ---- */
void eq_sort_order(const uint8_t *rows, size_t row_stride,
                   uint32_t *order, uint32_t *scratch, size_t n,
                   size_t prefix_len) {
    if (n < 2 || prefix_len == 0) return;
    uint32_t *src = order, *dst = scratch;
    for (size_t pos = prefix_len; pos > 0; pos--) {
        size_t counts[256] = {0};
        for (size_t i = 0; i < n; i++)
            counts[rows[(size_t)src[i] * row_stride + pos - 1]]++;
        size_t sum = 0;
        for (size_t c = 0; c < 256; c++) {
            size_t t = counts[c];
            counts[c] = sum;
            sum += t;
        }
        for (size_t i = 0; i < n; i++) {
            uint32_t idx = src[i];
            uint8_t b = rows[(size_t)idx * row_stride + pos - 1];
            dst[counts[b]++] = idx;
        }
        uint32_t *t = src;
        src = dst;
        dst = t;
    }
    if (src != order)
        memcpy(order, src, n * sizeof(uint32_t));
}

void eq_permute_rows(uint8_t *rows, size_t row_stride,
                     const uint32_t *order, size_t n,
                     uint8_t *tmp_row, uint8_t *visited) {
    memset(visited, 0, n);
    for (size_t i = 0; i < n; i++) {
        if (visited[i]) continue;
        size_t j = i;
        memcpy(tmp_row, rows + i * row_stride, row_stride);
        for (;;) {
            visited[j] = 1;
            size_t k = order[j];
            if (k == i) {
                memcpy(rows + j * row_stride, tmp_row, row_stride);
                break;
            }
            memcpy(rows + j * row_stride, rows + k * row_stride, row_stride);
            j = k;
        }
    }
}

size_t eq_find_buckets(const uint8_t *rows, size_t row_stride, size_t n,
                       size_t *bounds_out) {
    size_t nb = 0;
    bounds_out[0] = 0;
    size_t i = 0;
    while (i + 1 < n) {
        size_t j = i + 1;
        uint8_t bkey = rows[i * row_stride];
        while (j < n && rows[j * row_stride] == bkey) j++;
        nb++;
        bounds_out[nb] = j;
        i = j;
    }
    if (i < n) { /* trailing lone row forms no pairs; still delimit it */
        nb++;
        bounds_out[nb] = n;
    }
    return nb;
}

static int row_lt(const uint8_t *a, const uint8_t *b, size_t len) {
    return memcmp(a, b, len) < 0;
}

/* Combine rows a,b (hash_len current) into out, smaller index-list first. */
static void combine_rows(uint8_t *out, const uint8_t *a, const uint8_t *b,
                         size_t hash_len, size_t idx_len, size_t trim) {
    size_t i;
    for (i = trim; i < hash_len; i++) out[i - trim] = (uint8_t)(a[i] ^ b[i]);
    if (row_lt(a + hash_len, b + hash_len, idx_len)) {
        memcpy(out + hash_len - trim, a + hash_len, idx_len);
        memcpy(out + hash_len - trim + idx_len, b + hash_len, idx_len);
    } else {
        memcpy(out + hash_len - trim, b + hash_len, idx_len);
        memcpy(out + hash_len - trim + idx_len, a + hash_len, idx_len);
    }
}

/* Exact distinct-index check over 4-byte units (full rows only). */
static int distinct_indices(const uint8_t *a, const uint8_t *b,
                            size_t hash_len, size_t idx_len) {
    size_t i, j;
    for (i = 0; i < idx_len; i += 4)
        for (j = 0; j < idx_len; j += 4)
            if (memcmp(a + hash_len + i, b + hash_len + j, 4) == 0) return 0;
    return 1;
}

static int is_zero(const uint8_t *s, size_t len) {
    size_t i;
    for (i = 0; i < len; i++)
        if (s[i]) return 0;
    return 1;
}

/* Greedy full-pairing test (mirrors IsProbablyDuplicate).
 * Oversize input reports duplicate (safe direction for filters). */
static int probably_duplicate(const uint8_t *idxs, size_t len) {
    /* len <= 512 by construction (2^K indices max); fixed working set. */
    uint8_t checked[512];
    size_t count = 0, z, y;
    if (len > sizeof checked) return 1;
    memset(checked, 0, len);
    for (z = 0; z < len; z++) {
        if (!checked[z]) {
            for (y = z + 1; y < len; y++) {
                if (!checked[y] && idxs[z] == idxs[y]) {
                    checked[y] = 1;
                    count += 2;
                    break;
                }
            }
        }
    }
    return count == len;
}

/* Shared pair walk: counts or fills. */
static size_t walk_bucket(const uint8_t *rows, size_t row_stride,
                          const eq_geom_t *g, size_t blo, size_t bhi,
                          uint8_t *out, size_t out_stride, size_t out_cap,
                          int count_only) {
    size_t n = 0, i = blo;
    size_t hash_len = g->hash_bytes, idx_len = g->idx_bytes;
    /* Explicit geometry guard (asserts alone are not reliable): refuse
     * underflowing trims and rows wider than the scratch buffer. */
    if (g->trim_bytes > hash_len) return 0;
    if (hash_len + 2 * idx_len > 4096) return 0;
    while (i + 1 < bhi) {
        size_t j = i + 1;
        while (j < bhi && memcmp(rows + i * row_stride,
                                 rows + j * row_stride,
                                 g->prefix_bytes) == 0)
            j++;
        for (size_t l = i; l + 1 < j; l++) {
            for (size_t m = l + 1; m < j; m++) {
                const uint8_t *a = rows + l * row_stride;
                const uint8_t *b = rows + m * row_stride;
                uint8_t tmp[4096]; /* covers FinalFullWidth (2054) */
                assert(hash_len + 2 * idx_len <= sizeof tmp);
                combine_rows(tmp, a, b, hash_len, idx_len, g->trim_bytes);
                size_t nh = hash_len - g->trim_bytes;
                const uint8_t *ni = tmp + nh;
                int keep = 0;
                if (g->index_unit == 4) {
                    keep = distinct_indices(a, b, hash_len, idx_len);
                } else if (g->filter_mode == 1) {
                    keep = !(is_zero(tmp, nh) &&
                             probably_duplicate(ni, 2 * idx_len));
                } else { /* filter_mode 2: final partials */
                    keep = !probably_duplicate(ni, 2 * idx_len);
                }
                if (keep) {
                    /* On capacity violation keep counting but stop
                     * writing, so the return value visibly exceeds the
                     * cap and count-first callers detect misuse. */
                    if (!count_only && n < out_cap) {
                        memcpy(out + n * out_stride, tmp, nh + 2 * idx_len);
                    }
                    n++;
                }
            }
        }
        i = j;
    }
    return n;
}

size_t eq_count_pairs(const uint8_t *rows, size_t row_stride,
                      const eq_geom_t *g, size_t blo, size_t bhi) {
    return walk_bucket(rows, row_stride, g, blo, bhi, NULL, 0, 0, 1);
}

size_t eq_combine_bucket(const uint8_t *rows, size_t row_stride,
                         const eq_geom_t *g, size_t blo, size_t bhi,
                         uint8_t *out, size_t out_stride,
                         size_t out_cap_rows) {
    return walk_bucket(rows, row_stride, g, blo, bhi, out, out_stride,
                       out_cap_rows, 0);
}
