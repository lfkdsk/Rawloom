// Finishing.metal — merged linear RGB → display image. See docs/PIPELINE.md §6.
// Order: white balance → exposure → CCM → local+global tone map → saturation → sRGB.
// The tone map is a single-scale local-Laplacian approximation: a global Reinhard curve compresses
// range while local detail (luma minus a blurred luma) is added back so shadows lift without going
// flat.

#include <metal_stdlib>
using namespace metal;

struct FinishParams {
    uint  width;
    uint  height;
    float wbR, wbG, wbB;            // white-balance gains
    float m0, m1, m2, m3, m4, m5, m6, m7, m8; // CCM (camera RGB → linear sRGB), row-major
    float exposure;                // gain compensating the capture under-exposure
    float toneStrength;            // 0 = linear … 1 = full Reinhard
    float localContrast;           // detail add-back gain
    float saturation;
};

/// White balance + exposure + colour-correction matrix → linear (sRGB-primary) RGB.
kernel void finish_linearize(
    texture2d<float, access::read>  rgbIn  [[texture(0)]],
    texture2d<float, access::write> rgbOut [[texture(1)]],
    constant FinishParams&          p      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    float3 c = rgbIn.read(gid).rgb;
    c *= float3(p.wbR, p.wbG, p.wbB);
    c *= p.exposure;
    float3 cc = float3(
        p.m0 * c.r + p.m1 * c.g + p.m2 * c.b,
        p.m3 * c.r + p.m4 * c.g + p.m5 * c.b,
        p.m6 * c.r + p.m7 * c.g + p.m8 * c.b
    );
    rgbOut.write(float4(max(cc, float3(0.0)), 1.0), gid);
}

/// Luminance of a linear RGB image (for the tone map's base layer).
kernel void extract_luma(
    texture2d<float, access::read>  rgb  [[texture(0)]],
    texture2d<float, access::write> luma [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
    luma.write(float4(luminance(rgb.read(gid).rgb)), gid);
}

/// Separable-equivalent 5×5 Gaussian blur (single pass) used to form the tone map's base layer.
kernel void gaussian_blur5(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const float w[5] = {1.0, 4.0, 6.0, 4.0, 1.0};
    float acc = 0.0, wsum = 0.0;
    for (int j = -2; j <= 2; ++j) {
        for (int i = -2; i <= 2; ++i) {
            float wt = w[i + 2] * w[j + 2];
            acc += wt * read_clamped(src, int(gid.x) + i, int(gid.y) + j);
            wsum += wt;
        }
    }
    dst.write(float4(acc / wsum), gid);
}

/// Local + global tone map, saturation, and sRGB encode → 8-bit-ready display RGB.
kernel void tone_finish(
    texture2d<float, access::read>  rgbLinear [[texture(0)]],
    texture2d<float, access::read>  luma      [[texture(1)]],
    texture2d<float, access::read>  blurLuma  [[texture(2)]],
    texture2d<float, access::write> displayOut[[texture(3)]],
    constant FinishParams&          p         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    float3 c = rgbLinear.read(gid).rgb;
    float L = max(luma.read(gid).r, 1e-5);
    float base = max(blurLuma.read(gid).r, 1e-5);
    float detail = L - base;

    // Global tone curve on the (blurred) base, then re-inject local detail.
    float toneBase = mix(base, base / (1.0 + base), p.toneStrength);
    float newL = max(toneBase + detail * p.localContrast, 0.0);

    // Soft highlight knee: keep shadows/midtones linear, but roll the highlights off so a bright
    // (e.g. backlit window) region compresses smoothly toward — but never reaches — 1.0 instead of
    // hard-clipping to a flat white. Without this the memorised-gain lift blows out highlights.
    const float knee = 0.7;
    if (newL > knee) {
        float over = newL - knee;
        newL = knee + (1.0 - knee) * over / (over + (1.0 - knee));
    }

    // Black point + gentle contrast S-curve (the §6.8 "dehaze + global tone curve"): pull the floor to
    // true black so the image is not milky/grey, then add a mild hue-preserving S-contrast on luma.
    // This is the main fix for the flat/washed-out look; colour richness still wants a real CCM (§6.5).
    const float blackPoint = 0.035;
    newL = max(newL - blackPoint, 0.0) / (1.0 - blackPoint);
    const float contrast = 0.28;
    float sCurve = newL * newL * (3.0 - 2.0 * newL); // smoothstep
    newL = mix(newL, sCurve, contrast);

    // Scale RGB to the new luminance, preserving chroma ratios.
    float3 tm = c * (newL / L);

    // Saturation around the new luminance.
    float l2 = luminance(tm);
    tm = mix(float3(l2), tm, p.saturation);

    float3 outc = srgb_encode(clamp(tm, 0.0, 1.0));
    displayOut.write(float4(outc, 1.0), gid);
}
