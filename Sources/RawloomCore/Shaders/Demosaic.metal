// Demosaic.metal — Bayer → linear camera RGB. See docs/PIPELINE.md §6.4.
// Bilinear (gradient-free) interpolation: robust and cheap. The Malvar–He–Cutler 5×5 variant can
// drop in here later for sharper chroma; bilinear is the correctness baseline.

#include <metal_stdlib>
using namespace metal;

struct DemosaicParams {
    uint width;
    uint height;
    uint redX;   // x of the red pixel within the 2×2 cell
    uint redY;   // y of the red pixel within the 2×2 cell
};

kernel void demosaic_bilinear(
    texture2d<float, access::read>  bayer [[texture(0)]],
    texture2d<float, access::write> rgb   [[texture(1)]],
    constant DemosaicParams&        p     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x), y = int(gid.y);
    bool redRow = (uint(y) & 1u) == p.redY;
    bool redCol = (uint(x) & 1u) == p.redX;

    float c  = read_clamped(bayer, x, y);
    float l  = read_clamped(bayer, x - 1, y);
    float r  = read_clamped(bayer, x + 1, y);
    float u  = read_clamped(bayer, x, y - 1);
    float d  = read_clamped(bayer, x, y + 1);
    float ul = read_clamped(bayer, x - 1, y - 1);
    float ur = read_clamped(bayer, x + 1, y - 1);
    float dl = read_clamped(bayer, x - 1, y + 1);
    float dr = read_clamped(bayer, x + 1, y + 1);

    float cross = 0.25 * (l + r + u + d);
    float diag  = 0.25 * (ul + ur + dl + dr);

    float3 out;
    if (redRow && redCol) {            // R site
        out = float3(c, cross, diag);
    } else if (!redRow && !redCol) {   // B site
        out = float3(diag, cross, c);
    } else if (redRow && !redCol) {    // G on a red row: H neighbours R, V neighbours B
        out = float3(0.5 * (l + r), c, 0.5 * (u + d));
    } else {                           // G on a blue row: H neighbours B, V neighbours R
        out = float3(0.5 * (u + d), c, 0.5 * (l + r));
    }
    rgb.write(float4(max(out, float3(0.0)), 1.0), gid);
}
