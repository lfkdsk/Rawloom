// Pyramid.metal — Bayer → grayscale and Gaussian/box pyramid downsampling for alignment.
// See docs/PIPELINE.md §3.1.

#include <metal_stdlib>
using namespace metal;

/// Reduce a normalised Bayer mosaic to a single-channel grayscale at half resolution by averaging
/// each 2×2 RGGB quad. Halving keeps all motion in multiples of 2 Bayer px, preserving CFA phase.
kernel void bayer_to_gray(
    texture2d<float, access::read>  bayer [[texture(0)]],
    texture2d<float, access::write> gray  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint gw = gray.get_width(), gh = gray.get_height();
    if (gid.x >= gw || gid.y >= gh) return;
    uint x = gid.x * 2, y = gid.y * 2;
    float v = 0.25 * (read_clamped(bayer, int(x),     int(y)) +
                      read_clamped(bayer, int(x) + 1, int(y)) +
                      read_clamped(bayer, int(x),     int(y) + 1) +
                      read_clamped(bayer, int(x) + 1, int(y) + 1));
    gray.write(float4(v), gid);
}

/// Halve a single-channel image with a 2×2 box average (one octave of the pyramid). Applying it
/// `log2(factor)` times realises the per-level downsample factors (2, 4, 4) of the HDR+ pyramid.
kernel void downsample_half(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint dw = dst.get_width(), dh = dst.get_height();
    if (gid.x >= dw || gid.y >= dh) return;
    int x = int(gid.x) * 2, y = int(gid.y) * 2;
    float v = 0.25 * (read_clamped(src, x,     y) +
                      read_clamped(src, x + 1, y) +
                      read_clamped(src, x,     y + 1) +
                      read_clamped(src, x + 1, y + 1));
    dst.write(float4(v), gid);
}
