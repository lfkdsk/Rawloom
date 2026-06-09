// Common.metal — shared helpers for every Rawloom kernel.
//
// IMPORTANT: this file is concatenated FIRST into the runtime-compiled library (see
// MetalContext.loadLibrary), so anything defined here is visible to all other kernels. Per-kernel
// parameter structs live next to their own kernels; only genuinely shared helpers belong here.

#include <metal_stdlib>
using namespace metal;

// ------------------------------------------------------------------ sampling

/// Clamp-to-edge integer read from a single-channel float texture.
inline float read_clamped(texture2d<float, access::read> t, int x, int y) {
    int w = int(t.get_width());
    int h = int(t.get_height());
    x = clamp(x, 0, w - 1);
    y = clamp(y, 0, h - 1);
    return t.read(uint2(x, y)).r;
}

/// Bilinear sample of a single-channel float texture at fractional position `p` (pixel coords).
inline float bilinear(texture2d<float, access::read> t, float2 p) {
    float fx = floor(p.x);
    float fy = floor(p.y);
    float ax = p.x - fx;
    float ay = p.y - fy;
    int x0 = int(fx), y0 = int(fy);
    float v00 = read_clamped(t, x0,     y0);
    float v10 = read_clamped(t, x0 + 1, y0);
    float v01 = read_clamped(t, x0,     y0 + 1);
    float v11 = read_clamped(t, x0 + 1, y0 + 1);
    float top = mix(v00, v10, ax);
    float bot = mix(v01, v11, ax);
    return mix(top, bot, ay);
}

inline float4 read_clamped_rgba(texture2d<float, access::read> t, int x, int y) {
    int w = int(t.get_width());
    int h = int(t.get_height());
    x = clamp(x, 0, w - 1);
    y = clamp(y, 0, h - 1);
    return t.read(uint2(x, y));
}

/// Bilinear sample of an RGBA float texture at fractional `p` (pixel coords), clamp-to-edge.
inline float4 bilinear_rgba(texture2d<float, access::read> t, float2 p) {
    float fx = floor(p.x), fy = floor(p.y);
    float ax = p.x - fx, ay = p.y - fy;
    int x0 = int(fx), y0 = int(fy);
    float4 v00 = read_clamped_rgba(t, x0,     y0);
    float4 v10 = read_clamped_rgba(t, x0 + 1, y0);
    float4 v01 = read_clamped_rgba(t, x0,     y0 + 1);
    float4 v11 = read_clamped_rgba(t, x0 + 1, y0 + 1);
    return mix(mix(v00, v10, ax), mix(v01, v11, ax), ay);
}

// ------------------------------------------------------------------ complex math (float2 = a + bi)

inline float2 cmul(float2 a, float2 b) {
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}
inline float2 cconj(float2 a) { return float2(a.x, -a.y); }
inline float  cnorm2(float2 a) { return a.x * a.x + a.y * a.y; }

// ------------------------------------------------------------------ windows

/// Modified raised-cosine (Hann) window value at sample i of n: w = 0.5 - 0.5*cos(2π(i+0.5)/n).
/// Two of these, half-overlapped, sum to 1 — so DFT-tile overlap-add normalises itself.
inline float raised_cosine(uint i, uint n) {
    return 0.5 - 0.5 * cos(2.0 * M_PI_F * (float(i) + 0.5) / float(n));
}

// ------------------------------------------------------------------ colour

constant float3 kRec709Luma = float3(0.2126, 0.7152, 0.0722);
inline float luminance(float3 rgb) { return dot(rgb, kRec709Luma); }

/// Linear RGB → YUV (BT.709 full-range) and back. Used by chroma denoise and luma-only sharpening.
inline float3 rgb_to_yuv(float3 c) {
    float y = dot(c, kRec709Luma);
    float u = (c.b - y) * 0.5389;
    float v = (c.r - y) * 0.6350;
    return float3(y, u, v);
}
inline float3 yuv_to_rgb(float3 yuv) {
    float y = yuv.x, u = yuv.y, v = yuv.z;
    float r = y + v / 0.6350;
    float b = y + u / 0.5389;
    float g = (y - kRec709Luma.r * r - kRec709Luma.b * b) / kRec709Luma.g;
    return float3(r, g, b);
}

/// sRGB opto-electronic transfer (linear → display) and its inverse.
inline float srgb_encode(float x) {
    x = clamp(x, 0.0, 1.0);
    return (x <= 0.0031308) ? (12.92 * x) : (1.055 * pow(x, 1.0 / 2.4) - 0.055);
}
inline float3 srgb_encode(float3 c) {
    return float3(srgb_encode(c.r), srgb_encode(c.g), srgb_encode(c.b));
}
inline float srgb_decode(float x) {
    x = clamp(x, 0.0, 1.0);
    return (x <= 0.04045) ? (x / 12.92) : pow((x + 0.055) / 1.055, 2.4);
}

// ------------------------------------------------------------------ misc

inline float safe_div(float a, float b) { return a / max(b, 1e-8); }
inline float sqr(float x) { return x * x; }
