// RawProcessing.metal — ingest: sensor codes → normalised linear Bayer.

#include <metal_stdlib>
using namespace metal;

struct RawNormalizeParams {
    uint  width;
    uint  height;
    float blackR;
    float blackGr;
    float blackGb;
    float blackB;
    float whiteLevel;
    uint  redX;   // x of the red pixel within the 2×2 cell (0 or 1)
    uint  redY;   // y of the red pixel within the 2×2 cell (0 or 1)
};

/// Black-level subtract + white-level normalise a raw Bayer mosaic to linear [0,1].
/// Picks the correct per-Bayer-position black level from the pixel parity.
kernel void normalize_raw(
    texture2d<uint,  access::read>  inRaw   [[texture(0)]],
    texture2d<float, access::write> outImg  [[texture(1)]],
    constant RawNormalizeParams&    p       [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;

    uint code = inRaw.read(gid).r;

    bool redRow = (gid.y & 1u) == p.redY;
    bool redCol = (gid.x & 1u) == p.redX;
    float black;
    if (redRow && redCol)        black = p.blackR;   // R
    else if (redRow && !redCol)  black = p.blackGr;  // green on a red row
    else if (!redRow && redCol)  black = p.blackGb;  // green on a blue row
    else                         black = p.blackB;   // B

    float denom = max(p.whiteLevel - black, 1.0);
    float v = (float(code) - black) / denom;
    outImg.write(float4(clamp(v, 0.0, 1.0)), gid);
}
