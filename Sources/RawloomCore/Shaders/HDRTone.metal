// HDRTone.metal — the HDR rendition that feeds the Ultra HDR gain map. See docs/PIPELINE.md §7.
//
// Produces a *display-referred HDR* image in linear light: the same shadow/mid rendering as the SDR
// tone map (local detail add-back, black point, saturation) but with highlights extended toward an
// HDR ceiling instead of compressed toward 1. Pairing this HDR with the SDR display yields a gain map
// whose boost is concentrated in the highlights. Intentionally decoupled from `tone_finish` — it only
// has to be a good HDR, not a pixel-exact match of the SDR curve. Shared helpers come from Common.metal.

#include <metal_stdlib>
using namespace metal;

struct HDRToneParams {
    uint  width;
    uint  height;
    float localContrast;   // detail add-back gain (same value the SDR finish uses)
    float saturation;
    float ceiling;         // max HDR linear value (e.g. 4 → ~2 stops over SDR white)
};

kernel void tone_hdr(
    texture2d<float, access::read>  rgbLinear [[texture(0)]],
    texture2d<float, access::read>  luma      [[texture(1)]],
    texture2d<float, access::read>  blurLuma  [[texture(2)]],
    texture2d<float, access::write> hdrOut    [[texture(3)]],
    constant HDRToneParams&         p         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    float3 c = rgbLinear.read(gid).rgb;
    float L = max(luma.read(gid).r, 1e-5);
    float base = max(blurLuma.read(gid).r, 1e-5);
    float detail = L - base;

    // Extended Reinhard with white point = ceiling: near-identity through the mids (so HDR matches SDR
    // there), highlights preserved up to `ceiling` rather than squeezed toward 1. That preserved
    // headroom is exactly what the gain map encodes.
    float Lw = max(p.ceiling, 1.0);
    float toneBase = base * (1.0 + base / (Lw * Lw)) / (1.0 + base);
    float newL = max(toneBase + detail * p.localContrast, 0.0);

    // Same black point as the SDR finish, so shadows render identically (gain ≈ 1 there).
    const float blackPoint = 0.035;
    newL = max(newL - blackPoint, 0.0) / (1.0 - blackPoint);

    // Re-scale RGB to the new luminance (preserve chroma), then saturation around it. Output is LINEAR
    // (no sRGB encode, no clamp to 1) so the gain map sees true highlight headroom.
    float3 tm = c * (newL / L);
    float l2 = luminance(tm);
    tm = mix(float3(l2), tm, p.saturation);

    hdrOut.write(float4(clamp(tm, 0.0, Lw), 1.0), gid);
}
