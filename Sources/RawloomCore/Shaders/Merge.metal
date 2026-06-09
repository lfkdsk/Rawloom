// Merge.metal — robust multi-frame merge. See docs/PIPELINE.md §4.
//
// This is the spatial robust merge (§4.3): per pixel, per Bayer plane, alternates are averaged in
// with a Wiener-style weight that collapses to the reference when an alternate disagrees beyond the
// noise level — denoising static content while rejecting motion/misalignment (no ghosts). The four
// Bayer planes are carried as the RGBA channels of a half-resolution "planes" image; the mapping is
// purely positional (2×2 block → RGBA in raster order), so it is independent of the CFA phase — the
// actual colours are only interpreted later, in finishing, from the CFA metadata.

#include <metal_stdlib>
using namespace metal;

struct MergeParams {
    uint  width;       // plane (half-res) width
    uint  height;
    uint  tileSize;    // alignment field tile size (plane px)
    uint  tilesX;
    uint  tilesY;
    float robustness;  // c in A = cσ²/(cσ² + d²)
    float noiseA;      // σ²(x) = noiseA·x + noiseB
    float noiseB;
};

inline float2 read_vec(texture2d<float, access::read> f, uint x, uint y) {
    return f.read(uint2(min(x, uint(f.get_width()) - 1), min(y, uint(f.get_height()) - 1))).xy;
}

/// Bayer mosaic → 4 positional planes (half resolution), RGBA = block(0,0),(1,0),(0,1),(1,1).
kernel void extract_planes(
    texture2d<float, access::read>  bayer  [[texture(0)]],
    texture2d<float, access::write> planes [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= planes.get_width() || gid.y >= planes.get_height()) return;
    int x = int(gid.x) * 2, y = int(gid.y) * 2;
    float4 v = float4(read_clamped(bayer, x,     y),
                      read_clamped(bayer, x + 1, y),
                      read_clamped(bayer, x,     y + 1),
                      read_clamped(bayer, x + 1, y + 1));
    planes.write(v, gid);
}

/// Inverse of `extract_planes`: 4 planes → Bayer mosaic.
kernel void planes_to_bayer(
    texture2d<float, access::read>  planes [[texture(0)]],
    texture2d<float, access::write> bayer  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= bayer.get_width() || gid.y >= bayer.get_height()) return;
    uint px = gid.x / 2, py = gid.y / 2;
    float4 v = planes.read(uint2(px, py));
    uint k = (gid.y & 1u) * 2u + (gid.x & 1u);
    float out = (k == 0u) ? v.x : (k == 1u) ? v.y : (k == 2u) ? v.z : v.w;
    bayer.write(float4(out), gid);
}

/// Seed the accumulators with the reference (weight 1).
kernel void merge_init(
    texture2d<float, access::read>  refPlanes [[texture(0)]],
    texture2d<float, access::write> acc       [[texture(1)]],
    texture2d<float, access::write> wsum      [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= acc.get_width() || gid.y >= acc.get_height()) return;
    acc.write(refPlanes.read(gid), gid);
    wsum.write(float4(1.0), gid);
}

/// Add one aligned alternate's robust contribution to the accumulators. Ping-pong (separate in/out)
/// rather than read_write textures, so it works without Metal tier-2 read-write support.
kernel void merge_accumulate(
    texture2d<float, access::read>  refPlanes [[texture(0)]],
    texture2d<float, access::read>  altPlanes [[texture(1)]],
    texture2d<float, access::read>  field     [[texture(2)]],
    texture2d<float, access::read>  accIn     [[texture(3)]],
    texture2d<float, access::read>  wIn       [[texture(4)]],
    texture2d<float, access::write> accOut    [[texture(5)]],
    texture2d<float, access::write> wOut      [[texture(6)]],
    constant MergeParams&           p         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint tx = min(gid.x / p.tileSize, p.tilesX - 1);
    uint ty = min(gid.y / p.tileSize, p.tilesY - 1);
    float2 u = read_vec(field, tx, ty);

    float4 r = refPlanes.read(gid);
    float4 a = bilinear_rgba(altPlanes, float2(float(gid.x) + u.x, float(gid.y) + u.y));

    float4 d = a - r;
    float4 sigma2 = max(p.noiseA * r + p.noiseB, float4(1e-8));
    float4 cs = p.robustness * sigma2;
    float4 w = cs / (cs + d * d);   // → 1 when alt agrees, → 0 when it disagrees beyond noise

    accOut.write(accIn.read(gid) + w * a, gid);
    wOut.write(wIn.read(gid) + w, gid);
}

/// Normalise the accumulators into the merged planes.
kernel void merge_finalize(
    texture2d<float, access::read>  acc  [[texture(0)]],
    texture2d<float, access::read>  wsum [[texture(1)]],
    texture2d<float, access::write> out  [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float4 w = max(wsum.read(gid), float4(1e-6));
    out.write(acc.read(gid) / w, gid);
}
