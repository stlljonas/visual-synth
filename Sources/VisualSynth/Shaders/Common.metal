// Shared by all shaders. The files in this folder are concatenated (Common.metal
// first, then the rest alphabetically) and compiled at runtime, so editing them
// while the app runs reloads them live.
//
// Conventions
// -----------
// Generator:  fragment float4 gen_xxx(VOut in [[stage_in]],
//                                     constant Globals& g [[buffer(0)]],
//                                     constant float* p [[buffer(1)]],     // its params, in spec order
//                                     constant GenCommon& c [[buffer(2)]])
//             return gen_out(mask, hueOffset, g, c);   // mask 0…1, colour/brightness/gate/blend handled there
//
// Effect:     fragment float4 fx_xxx(VOut in [[stage_in]],
//                                    constant Globals& g [[buffer(0)]],
//                                    constant float* p [[buffer(1)]],
//                                    constant FxCommon& c [[buffer(2)]],
//                                    texture2d<float> src [[texture(0)]],   // the image so far
//                                    texture2d<float> prev [[texture(1)]])  // last frame's final output
//             return fx_out(dry, wet, c);              // applies the Mix slider
//
// Coordinates: in.uv is 0…1 with (0,0) top-left (for sampling textures);
// in.p is centred, aspect-correct: y in -1…1 (up), x in -aspect…aspect.
// Keep edges sharp at any resolution with aa_* helpers (they use fwidth).

#include <metal_stdlib>
using namespace metal;

struct Globals {
    float2 res;       // render target size in pixels
    float time;       // seconds since start
    float dt;         // seconds since last frame
    float aspect;     // res.x / res.y
    float pulse;      // note envelope: jumps to velocity on note-on, decays (Master › Note decay)
    float note;       // last note number / 127
    float velocity;   // last velocity 0…1
    float gate;       // 1 while any note is held (smoothed)
    float trigger;    // counts note-ons (use as a random seed per hit)
    float beat;       // beats since start (MIDI clock if present, else Master › Tempo)
    float bpm;
    float mod;        // mod wheel (CC1) 0…1
    float bass, mid, high;   // Mac audio band levels 0…1 (Master › Sync to Mac audio)
    float palOn, palShift, palSpread, palCount;   // Colour Palette card
    float4 pal[5];                                // palette colour stops (rgb)
};

/// Colour at position t (wraps) along the palette loop.
inline float3 palette_at(constant Globals& g, float t) {
    float n = max(g.palCount, 1.0);
    float x = fract(t) * n;
    int i = int(floor(x)) % int(n);
    int j = (i + 1) % int(n);
    float f = smoothstep(0.0, 1.0, fract(x));
    return mix(g.pal[i].rgb, g.pal[j].rgb, f);
}

struct GenCommon {
    float hue, sat, bright, gate, blend, _p0, _p1, _p2;
};

struct FxCommon {
    float mix, _p0, _p1, _p2, _p3, _p4, _p5, _p6;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
    float2 p;
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler linearRepeat(filter::linear, address::repeat);
constexpr sampler linearMirror(filter::linear, address::mirrored_repeat);
constexpr sampler nearestClamp(filter::nearest, address::clamp_to_edge);
/// For effects with `mips: true`: src.sample(mipClamp, uv, level(lod)) reads a pre-shrunk copy.
/// Levels 0…7 exist (Renderer.mipLevels).
constexpr sampler mipClamp(filter::linear, mip_filter::linear, address::clamp_to_edge, lod_clamp(0.0f, 7.0f));

vertex VOut vs_full(uint vid [[vertex_id]], constant Globals& g [[buffer(0)]]) {
    float2 xy = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2): one triangle covers the screen
    VOut o;
    o.pos = float4(xy * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(xy.x, 1.0 - xy.y);
    o.p = float2((o.uv.x * 2.0 - 1.0) * g.aspect, 1.0 - o.uv.y * 2.0);
    return o;
}

// ---------- helpers ----------

constant float PI = 3.14159265358979;
constant float TAU = 6.28318530717959;

inline float2x2 rot2(float a) { float c = cos(a), s = sin(a); return float2x2(c, s, -s, c); }

inline float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), saturate(p - 1.0), c.y);
}

inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// Integer hashes (PCG): cheaper than the classic sin() hash and free of its precision artefacts.
// Inputs are reinterpreted as bits, so nearby floats give unrelated results.
inline uint2 pcg2d(uint2 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * 1664525u; v.y += v.x * 1664525u;
    v ^= v >> 16u;
    v.x += v.y * 1664525u; v.y += v.x * 1664525u;
    v ^= v >> 16u;
    return v;
}
inline float hash11(float x) { return float(pcg2d(uint2(as_type<uint>(x + 0.0), 0x9e3779b9u)).x) * 2.3283064e-10; }
inline float hash21(float2 p) { return float(pcg2d(as_type<uint2>(p + 0.0)).x) * 2.3283064e-10; }
inline float2 hash22(float2 p) { return float2(pcg2d(as_type<uint2>(p + 0.0))) * 2.3283064e-10; }

inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

/// Antialiased fill of a signed distance (inside < 0), crisp at any resolution.
/// `soft` (0…1) widens the edge for a glow-ish look.
inline float aa_fill(float d, float soft) {
    float w = max(fwidth(d), 1e-5) * 0.75 + soft;
    return 1.0 - smoothstep(-w, w, d);
}

/// Antialiased line of half-thickness `r` around a distance `d`.
inline float aa_line(float d, float r, float soft) { return aa_fill(abs(d) - r, soft); }

/// Colour a generator's mask with its Hue / Saturation / Brightness / Note gate / Blend.
inline float4 gen_out(float mask, float hueOffset, constant Globals& g, constant GenCommon& c) {
    mask = saturate(mask);
    float k = c.bright * mix(1.0, g.pulse, c.gate);
    float3 col;
    if (g.palOn > 0.5) {
        // palette mode: Hue picks the spot on the palette; Saturation below 0.75 fades toward grey
        col = palette_at(g, c.hue + g.palShift + hueOffset * g.palSpread);
        col = mix(float3(luma(col)), col, saturate(c.sat / 0.75)) * k;
    } else {
        col = hsv2rgb(float3(fract(c.hue + hueOffset), c.sat, 1.0)) * k;
    }
    if (c.blend > 2.5) {                 // Multiply: untouched where the mask is empty
        return float4(mix(float3(1.0), col, mask), 1.0);
    }
    return float4(col * mask, mask);
}

inline float4 fx_out(float4 dry, float4 wet, constant FxCommon& c) {
    return mix(dry, wet, c.mix);
}

// ---------- built-in passes ----------

/// Mip chain: half-size copy of the level above (bilinear tap = 2×2 box).
fragment float4 downsample(VOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return src.sample(linearClamp, in.uv);
}

/// Final pass onto the screen: master brightness & contrast.
fragment float4 present(VOut in [[stage_in]],
                        constant float* p [[buffer(1)]],
                        texture2d<float> src [[texture(0)]]) {
    float3 c = src.sample(linearClamp, in.uv).rgb * p[2];
    c = (c - 0.5) * p[3] + 0.5;
    return float4(saturate(c), 1.0);
}
