// Alignment.metal — coarse-to-fine tile block matching. See docs/PIPELINE.md §3.2.

#include <metal_stdlib>
using namespace metal;

struct AlignParams {
    uint  levelWidth;    // gray width at this pyramid level
    uint  levelHeight;
    uint  tileSize;      // block-match tile edge (px) at this level
    uint  tilesX;        // tile grid dimensions
    uint  tilesY;
    int   searchRadius;  // ±R integer search
    float lambda;        // motion regularisation weight
    uint  useL1;         // 1 = L1 (finest), 0 = L2 (coarse)
    uint  hasPrior;      // 1 if priorField is valid
    uint  subpixel;      // 1 = quadratic sub-pixel refine (skip at the finest level)
};

// --- rg32Float (vector field) sampling helpers ---------------------------------------------------

inline float2 read_field(texture2d<float, access::read> f, int x, int y) {
    int w = int(f.get_width()), h = int(f.get_height());
    x = clamp(x, 0, w - 1);
    y = clamp(y, 0, h - 1);
    return f.read(uint2(x, y)).xy;
}

inline float2 bilinear_field(texture2d<float, access::read> f, float2 p) {
    float fx = floor(p.x), fy = floor(p.y);
    float ax = p.x - fx, ay = p.y - fy;
    int x0 = int(fx), y0 = int(fy);
    float2 v00 = read_field(f, x0,     y0);
    float2 v10 = read_field(f, x0 + 1, y0);
    float2 v01 = read_field(f, x0,     y0 + 1);
    float2 v11 = read_field(f, x0 + 1, y0 + 1);
    return mix(mix(v00, v10, ax), mix(v01, v11, ax), ay);
}

// --- block-match cost ----------------------------------------------------------------------------

/// Sum of L1/L2 distance between the reference tile at `origin` and the alternate tile displaced by
/// `disp` (sampled bilinearly, so sub-pixel `disp` is allowed).
static float tile_cost(
    texture2d<float, access::read> ref,
    texture2d<float, access::read> alt,
    int2 origin, float2 disp, uint tileSize, bool useL1
) {
    float cost = 0.0;
    for (uint j = 0; j < tileSize; ++j) {
        for (uint i = 0; i < tileSize; ++i) {
            float r = read_clamped(ref, origin.x + int(i), origin.y + int(j));
            float a = bilinear(alt, float2(float(origin.x + int(i)) + disp.x,
                                           float(origin.y + int(j)) + disp.y));
            float d = r - a;
            cost += useL1 ? fabs(d) : d * d;
        }
    }
    return cost;
}

/// Align one pyramid level: per tile, pick the best of a few upsampled prior candidates, do an
/// integer ±R search, then a quadratic sub-pixel refine. Writes the per-tile vector field.
kernel void align_level(
    texture2d<float, access::read>  refGray   [[texture(0)]],
    texture2d<float, access::read>  altGray   [[texture(1)]],
    texture2d<float, access::read>  priorField[[texture(2)]],
    texture2d<float, access::write> outField  [[texture(3)]],
    constant AlignParams&           p         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.tilesX || gid.y >= p.tilesY) return;
    int2 origin = int2(int(gid.x * p.tileSize), int(gid.y * p.tileSize));

    // 1. choose the best starting vector among the prior tile and its 4 neighbours.
    float2 u0 = float2(0.0);
    if (p.hasPrior != 0u) {
        float2 cand[5];
        cand[0] = read_field(priorField, int(gid.x),     int(gid.y));
        cand[1] = read_field(priorField, int(gid.x) - 1, int(gid.y));
        cand[2] = read_field(priorField, int(gid.x) + 1, int(gid.y));
        cand[3] = read_field(priorField, int(gid.x),     int(gid.y) - 1);
        cand[4] = read_field(priorField, int(gid.x),     int(gid.y) + 1);
        float bestC = FLT_MAX;
        for (uint k = 0; k < 5; ++k) {
            float c = tile_cost(refGray, altGray, origin, cand[k], p.tileSize, p.useL1 != 0u);
            if (c < bestC) { bestC = c; u0 = cand[k]; }
        }
    }

    // 2. integer search ±R around u0 with a mild motion regulariser.
    float2 best = float2(0.0);
    float bestCost = FLT_MAX;
    for (int dy = -p.searchRadius; dy <= p.searchRadius; ++dy) {
        for (int dx = -p.searchRadius; dx <= p.searchRadius; ++dx) {
            float2 disp = u0 + float2(float(dx), float(dy));
            float c = tile_cost(refGray, altGray, origin, disp, p.tileSize, p.useL1 != 0u);
            c += p.lambda * float(dx * dx + dy * dy);
            if (c < bestCost) { bestCost = c; best = float2(float(dx), float(dy)); }
        }
    }

    // 3. quadratic sub-pixel refinement (skipped at the finest level to avoid mixing Bayer planes).
    float2 sub = float2(0.0);
    if (p.subpixel != 0u) {
        float2 c0 = u0 + best;
        float cc = tile_cost(refGray, altGray, origin, c0, p.tileSize, p.useL1 != 0u);
        float cxl = tile_cost(refGray, altGray, origin, c0 + float2(-1, 0), p.tileSize, p.useL1 != 0u);
        float cxr = tile_cost(refGray, altGray, origin, c0 + float2( 1, 0), p.tileSize, p.useL1 != 0u);
        float cyl = tile_cost(refGray, altGray, origin, c0 + float2(0, -1), p.tileSize, p.useL1 != 0u);
        float cyr = tile_cost(refGray, altGray, origin, c0 + float2(0,  1), p.tileSize, p.useL1 != 0u);
        float dxden = (cxl - 2.0 * cc + cxr);
        float dyden = (cyl - 2.0 * cc + cyr);
        if (dxden > 1e-6) sub.x = clamp(0.5 * (cxl - cxr) / dxden, -1.0, 1.0);
        if (dyden > 1e-6) sub.y = clamp(0.5 * (cyl - cyr) / dyden, -1.0, 1.0);
    }

    outField.write(float4(u0 + best + sub, 0.0, 0.0), gid);
}

struct UpsampleParams {
    uint  outTilesX;
    uint  outTilesY;
    uint  inTilesX;
    uint  inTilesY;
    float scale;      // multiply vectors by the resolution ratio between the two levels
};

/// Resize a coarser tile field to a finer tile grid (bilinear) and scale the vectors so they are
/// expressed in the finer level's pixels — used as the starting guess for `align_level`.
kernel void upsample_field(
    texture2d<float, access::read>  inField  [[texture(0)]],
    texture2d<float, access::write> outField [[texture(1)]],
    constant UpsampleParams&        p        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.outTilesX || gid.y >= p.outTilesY) return;
    float u = (float(gid.x) + 0.5) / float(p.outTilesX) * float(p.inTilesX) - 0.5;
    float v = (float(gid.y) + 0.5) / float(p.outTilesY) * float(p.inTilesY) - 0.5;
    float2 vec = bilinear_field(inField, float2(u, v)) * p.scale;
    outField.write(float4(vec, 0.0, 0.0), gid);
}

struct WarpParams {
    uint width;
    uint height;
    uint tileSize;
    uint tilesX;
    uint tilesY;
};

/// Warp a single-channel image by a per-tile vector field (nearest tile): out(x,y) = alt(x+u, y+u).
/// Used to validate alignment and (in the merge) to fetch aligned tiles.
kernel void warp_gray(
    texture2d<float, access::read>  alt   [[texture(0)]],
    texture2d<float, access::read>  field [[texture(1)]],
    texture2d<float, access::write> out   [[texture(2)]],
    constant WarpParams&            p     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint tx = min(gid.x / p.tileSize, p.tilesX - 1);
    uint ty = min(gid.y / p.tileSize, p.tilesY - 1);
    float2 u = read_field(field, int(tx), int(ty));
    float val = bilinear(alt, float2(float(gid.x) + u.x, float(gid.y) + u.y));
    out.write(float4(val), gid);
}
