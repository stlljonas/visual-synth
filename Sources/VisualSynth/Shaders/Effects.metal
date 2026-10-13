// Effects: see the conventions in Common.metal.

fragment float4 fx_echo(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                        constant float* p [[buffer(1)]], constant FxCommon& c [[buffer(2)]],
                        texture2d<float> src [[texture(0)]], texture2d<float> prev [[texture(1)]]) {
    float fb = p[0], zoom = p[1], rotS = p[2] * PI / 180.0;
    float2 drift = float2(p[3], p[4]) * 0.01;
    float hueShift = p[5], mode = p[6];
    float4 dry = src.sample(linearClamp, in.uv);
    // transform in centred, aspect-correct space
    float2 q = (in.uv - 0.5) * float2(g.aspect, 1.0);
    q = rot2(rotS * g.dt) * q / (1.0 + zoom) - drift * float2(1, -1);
    float2 uv = q / float2(g.aspect, 1.0) + 0.5;
    float4 echo = prev.sample(linearClamp, uv) * fb;
    if (abs(hueShift) > 1e-4) {
        float3 h = rgb2hsv(echo.rgb);
        echo.rgb = hsv2rgb(float3(fract(h.x + hueShift * 0.1), h.y, h.z));
    }
    float in_bounds = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
    echo *= in_bounds;
    float4 wet = mode < 0.5 ? max(dry, echo) : dry + echo;
    return fx_out(dry, wet, c);
}

fragment float4 fx_chroma(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                          constant float* p [[buffer(1)]], constant FxCommon& c [[buffer(2)]],
                          texture2d<float> src [[texture(0)]], texture2d<float> prev [[texture(1)]]) {
    float amount = p[0], angle = p[1] * PI / 180.0, rate = p[2], depth = p[3], kick = p[4];
    float lfo = 1.0 + depth * sin(g.beat * rate * TAU);
    float a = amount * lfo * (1.0 + kick * g.pulse * 3.0);
    float2 dir = float2(cos(angle), sin(angle)) * a * float2(1.0 / g.aspect, 1.0);
    float4 dry = src.sample(linearClamp, in.uv);
    float r = src.sample(linearClamp, in.uv + dir).r;
    float b = src.sample(linearClamp, in.uv - dir).b;
    float4 wet = float4(r, dry.g, b, dry.a);
    return fx_out(dry, wet, c);
}

// ---------- helpers for effects ----------

#define FX_ARGS VOut in [[stage_in]], constant Globals& g [[buffer(0)]], \
                constant float* p [[buffer(1)]], constant FxCommon& c [[buffer(2)]], \
                texture2d<float> src [[texture(0)]], texture2d<float> prev [[texture(1)]]

/// Centred, aspect-correct coordinates (like in.p) → texture uv, and back.
inline float2 fx_uv(float2 q, float aspect) { return float2(q.x / aspect * 0.5 + 0.5, 0.5 - q.y * 0.5); }
inline float2 fx_p(float2 uv, float aspect) { return float2((uv.x * 2.0 - 1.0) * aspect, 1.0 - uv.y * 2.0); }

/// Interleaved gradient noise (0…1) from pixel coords: cheap per-pixel jitter.
inline float fx_ign(float2 px) { return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715)))); }

/// Golden-angle (Vogel) disc blur: `n` taps spread evenly over an ellipse of radii `r` (uv units),
/// weighted exp(-k·d²). `rot` rotates the pattern; per-pixel jitter trades ghost copies for fine grain.
inline float4 fx_disc(texture2d<float> t, float2 uv, float2 r, int n, float rot, float k, float lod = 0.0) {
    float4 acc = 0.0;
    float ws = 0.0;
    float2 d = float2(cos(rot), sin(rot));
    const float2x2 golden = rot2(2.39996323);
    for (int i = 0; i < n; i++) {
        float rr = sqrt((float(i) + 0.5) / float(n));
        float w = exp(-k * rr * rr);
        acc += t.sample(mipClamp, uv + d * rr * r, level(lod)) * w;
        ws += w;
        d = golden * d;
    }
    return acc / ws;
}

/// Sample with a choice of edge handling: 0 mirror, 1 repeat, 2 black.
inline float4 fx_sample_edges(texture2d<float> t, float2 uv, int edges) {
    if (edges == 0) return t.sample(linearMirror, uv);
    if (edges == 1) return t.sample(linearRepeat, uv);
    float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
    return t.sample(linearClamp, uv) * inside;
}

// ---------- Transform (pan / zoom) ----------

fragment float4 fx_transform(FX_ARGS) {
    float zoomOct = p[0] + p[7] * g.pulse + p[8] * sin(g.beat * p[9] * TAU);
    float angle = p[1] * PI / 180.0 + g.beat * p[2] * TAU;
    float2 pan = float2(p[3], p[4]);
    float tiles = max(1.0, p[5]);
    int edges = int(p[6]);
    float4 dry = src.sample(linearClamp, in.uv);
    float2 q = rot2(-angle) * (in.p - pan) * exp2(-zoomOct);
    float2 uv = fx_uv(q, g.aspect);
    uv = (uv - 0.5) * tiles + 0.5;
    if (tiles > 1.0 && edges == 2) uv = fract(uv);   // tiles always repeat; Black only outside the grid
    float4 wet = fx_sample_edges(src, uv, edges);
    return fx_out(dry, wet, c);
}

// ---------- Kaleidoscope (unison) ----------

fragment float4 fx_kaleido(FX_ARGS) {
    int mode = int(p[0]);
    float n = max(2.0, p[1]);
    float angle = p[2] * PI / 180.0 + g.beat * p[3] * TAU;
    float zoom = exp2(p[4] + p[8] * g.pulse);
    float2 centre = float2(p[5] * g.aspect, p[6]);
    float pan = p[7];
    float4 dry = src.sample(linearClamp, in.uv);
    float2 q = in.p - centre;
    if (mode == 0) {
        float seg = TAU / n;
        float a = atan2(q.y, q.x) + angle;
        a -= seg * floor(a / seg);
        a = abs(a - seg * 0.5);                       // mirror inside each wedge: seamless
        q = length(q) * float2(cos(a), sin(a));
    } else {
        q = rot2(angle) * q;
        if (mode != 2) q.x = abs(q.x);
        if (mode != 1) q.y = abs(q.y);
        q = rot2(-angle) * q;
    }
    q = q / zoom + float2(pan * g.aspect, 0.0) + centre;
    float4 wet = src.sample(linearMirror, fx_uv(q, g.aspect));
    return fx_out(dry, wet, c);
}

// ---------- Ripple (phaser / flanger) ----------

inline float2 fx_ripple(float2 q, int dir, float A, float k, float ph) {
    if (dir == 0) return q + float2(A * sin(q.y * k + ph), 0.0);
    if (dir == 1) return q + float2(0.0, A * sin(q.x * k + ph));
    float r = length(q);
    float s = sin(r * k - ph);
    if (dir == 2) return q + (r > 1e-4 ? q / r : float2(0.0)) * A * s;
    return rot2(A * s / max(r, 0.15)) * q;           // twist
}

fragment float4 fx_phaser(FX_ARGS) {
    float freq = p[1], rate = p[2], spread = p[7];
    int dir = int(p[3]);
    float A = 2.0 * p[0] * (1.0 + p[4] * sin(g.beat * p[5] * TAU)) * (1.0 + p[6] * g.pulse);
    float k = freq * PI, ph = g.beat * rate * TAU;
    float4 dry = src.sample(linearClamp, in.uv);
    float4 wet = src.sample(linearMirror, fx_uv(fx_ripple(in.p, dir, A, k, ph), g.aspect));
    if (spread > 0.001) {
        float o = spread * 2.0;
        wet.r = src.sample(linearMirror, fx_uv(fx_ripple(in.p, dir, A, k, ph + o), g.aspect)).r;
        wet.b = src.sample(linearMirror, fx_uv(fx_ripple(in.p, dir, A, k, ph - o), g.aspect)).b;
    }
    return fx_out(dry, wet, c);
}

// ---------- Glitch (stutter) ----------

fragment float4 fx_glitch(FX_ARGS) {
    float amount = p[0], density = p[1], bh = p[2], bw = p[3], split = p[4];
    float react = p[5], rate = p[6], hold = p[7], invert = p[8], jitter = p[9];
    float seed = floor(g.trigger) * 1.618 + (rate > 0.0 ? floor(g.beat * rate) * 7.31 : 0.0);
    float env = mix(1.0, saturate(g.pulse), react);
    float4 dry = src.sample(linearClamp, in.uv);

    // block grid, re-cut for every seed
    float2 bs = float2(bw, bh) * mix(0.5, 1.5, hash11(seed + 0.37));
    float row = floor(in.uv.y / bs.y + hash11(seed + 0.11));
    float2 cell = float2(floor(in.uv.x / bs.x + hash11(row + seed)), row);
    float2 h = hash22(cell + seed * 13.17);
    bool active = h.x < density * env;

    float2 px = 1.0 / g.res;
    float2 off = 0.0;
    float sp = 0.0;
    if (active) {
        off.x = (h.y - 0.5) * 2.0 * amount * env;
        off.y = (hash21(cell + seed) - 0.5) * 0.1 * amount * env;
        sp = split * env * (h.y < 0.5 ? -1.0 : 1.0);
    }
    // scanline jitter: thin rows wobble a few pixels
    float line = floor(in.pos.y / 3.0);
    off.x += (hash21(float2(line, seed)) - 0.5) * jitter * 24.0 * px.x * env
             * step(0.7, hash21(float2(line * 0.37, seed + 3.0)));
    // whole-pixel offsets keep the image sharp
    off = round(off * g.res) * px;
    float sx = round(sp * g.res.x) * px.x;
    float2 uv = in.uv + off;
    float4 wet = src.sample(linearClamp, uv);
    if (sx != 0.0) {
        wet.r = src.sample(linearClamp, uv + float2(sx, 0.0)).r;
        wet.b = src.sample(linearClamp, uv - float2(sx, 0.0)).b;
    }
    if (active) {
        float r = hash21(cell + seed * 3.7 + 5.0);
        if (r < hold) wet = prev.sample(linearClamp, in.uv);                  // frozen: last frame
        else if (r < hold + invert) wet.rgb = max(float3(0.0), 1.0 - wet.rgb);
    }
    return fx_out(dry, wet, c);
}

// ---------- Bitcrusher (pixelate) ----------

constant float BAYER4[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

fragment float4 fx_crush(FX_ARGS) {
    float size = p[0] * (1.0 + p[6] * g.pulse), dither = p[2], shape = p[4], grid = p[5];
    float levels = exp2(max(1.0, p[1])) - 1.0;
    int mode = int(p[3]);
    float4 dry = src.sample(linearClamp, in.uv);
    float px = max(1.0, size * g.res.y / 1000.0);
    float2 bs = max(float2(1.0), round(px * float2(exp2(shape * 0.5), exp2(-shape * 0.5))));
    float2 cell = floor(in.pos.xy / bs);
    float4 s = src.sample(nearestClamp, ((cell + 0.5) * bs) / g.res);
    uint2 ci = uint2(cell);
    float b = (BAYER4[(ci.y & 3) * 4 + (ci.x & 3)] + 0.5) / 16.0 - 0.5;
    float3 col = mode == 1 ? float3(luma(s.rgb)) : s.rgb;
    col = floor(col * levels + 0.5 + b * dither) / levels;
    if (grid > 0.0 && bs.x > 2.0) {
        float2 f = fract(in.pos.xy / bs) * bs;              // pixel inside the block
        float edge = (f.x < 1.0 || f.y < 1.0) ? 1.0 : 0.0;
        col *= 1.0 - grid * edge;
    }
    return fx_out(dry, float4(max(col, 0.0), s.a), c);
}

// ---------- Ring mod (pattern) ----------

/// Carrier wave, -1…1; `sharp` 0 = sine, 1 = antialiased square.
inline float fx_wave(float ph, float sharp) {
    float w = mix(1.0, max(fwidth(ph), 1e-4) * 1.2, sharp);
    return clamp(cos(ph) / w, -1.0, 1.0);
}

fragment float4 fx_ringmod(FX_ARGS) {
    int shape = int(p[0]), mode = int(p[6]);
    float freq = p[1] * exp2(p[7] * (g.note * 127.0 - 60.0) / 12.0);
    float t = g.beat * p[2] * TAU, angle = p[3] * PI / 180.0, sharp = p[5];
    float depth = p[4] * mix(1.0, saturate(g.pulse), p[8]);
    float4 dry = src.sample(linearClamp, in.uv);
    float2 q = in.p;
    float k = freq * PI;
    float car;
    if (shape == 0) {
        car = fx_wave(dot(q, float2(cos(angle), sin(angle))) * k - t, sharp);
    } else if (shape == 1) {
        car = fx_wave(length(q) * k - t, sharp);
    } else if (shape == 2) {
        float2 r = rot2(angle) * q * k;
        car = fx_wave(r.x - t, sharp) * fx_wave(r.y, sharp);
    } else if (shape == 3) {
        float ph = atan2(q.y, q.x) * 3.0 + length(q) * k - t + angle;
        float w = mix(1.0, max(fwidth(length(q) * k), 1e-4) * 3.0, sharp);   // atan has a seam: use the radial rate
        car = clamp(cos(ph) / w, -1.0, 1.0);
    } else {
        float2 r = q * k * 0.25;
        float ph = sin(r.x + t * 0.5) + sin(r.y * 1.3 - t * 0.37) + sin((r.x + r.y) * 0.7 + t * 0.23)
                 + sin(length(r + float2(sin(t * 0.13), cos(t * 0.17)) * 3.0) * 1.5);
        car = fx_wave(ph * 2.0 + angle, sharp);
    }
    float3 col;
    if (mode == 0) {
        col = dry.rgb * (0.5 + 0.5 * car);
    } else {
        // ring: negative half = "phase-inverted" image, shown as the complementary colour
        float3 comp = (max3(dry.r, dry.g, dry.b) + min3(dry.r, dry.g, dry.b)) - dry.rgb;
        col = car >= 0.0 ? dry.rgb * car : comp * -car;
    }
    float4 wet = float4(mix(dry.rgb, col, depth), dry.a);
    return fx_out(dry, wet, c);
}

// ---------- Drive (distortion) ----------

inline float3 fx_curve(float3 x, int mode, float drive) {
    switch (mode) {
        case 0: return precise::tanh(x) / precise::tanh(max(drive, 1e-3));
        case 1: return clamp(x, 0.0, 1.0);
        case 2: return abs(fract(x * 0.5 + 0.5) * 2.0 - 1.0);              // triangle fold
        case 3: return 0.5 - 0.5 * cos(x * PI);                           // sine fold
        default: return floor(x + 0.5) / max(drive, 1.0);                 // posterize: `drive` steps
    }
}

fragment float4 fx_distort(FX_ARGS) {
    float drive = p[0] * (1.0 + p[6] * g.pulse), bias = p[2], asym = p[3], perChan = p[4], level = p[5];
    int mode = int(p[1]);
    float4 dry = src.sample(linearClamp, in.uv);
    float3 d = drive * float3(1.0, 1.0 + asym, 1.0 + 2.0 * asym);
    if (mode == 4) {   // posterize: drive = number of steps; bias shifts the thresholds
        d = max(1.0, round(d));
    }
    float3 chan = fx_curve(dry.rgb * d + bias, mode, drive);
    if (mode == 4) chan = floor(dry.rgb * d + 0.5 + bias) / d;
    float l = luma(dry.rgb);
    float lc = fx_curve(float3(l * drive + bias), mode, drive).x;
    if (mode == 4) lc = floor(l * max(1.0, round(drive)) + 0.5 + bias) / max(1.0, round(drive));
    float3 lum = dry.rgb * (lc / max(l, 1e-3));
    float3 col = mix(lum, chan, perChan) * level;
    return fx_out(dry, float4(max(col, 0.0), dry.a), c);
}

// ---------- Filter (LP / HP / BP) ----------

fragment float4 fx_filter(FX_ARGS) {
    float res = p[1], level = p[7];
    int mode = int(p[2]);
    float cut = p[0] + p[3] * g.pulse + p[4] * 0.5 * sin(g.beat * p[5] * TAU) + p[6] * (g.note - 0.5);
    cut = saturate(cut);
    float rpx = 0.06 * g.res.y * exp2(-9.0 * cut);       // blur radius in pixels: 100 px … sub-pixel
    float4 dry = src.sample(linearClamp, in.uv);
    float2 r = rpx / g.res;
    float rot = 0.3;   // fixed pattern: mip sampling already smooths, jitter only costs cache
    float lod = max(0.0, log2(rpx / sqrt(14.0) * 0.7));
    float4 lp = rpx > 0.4 ? fx_disc(src, in.uv, r, 14, rot, 2.0, lod) : dry;
    float4 lpHalf = (res > 0.001 || mode == 2) && rpx > 0.8
        ? fx_disc(src, in.uv, r * 0.45, 8, rot + 1.3, 2.0, max(0.0, lod - 1.0)) : dry;
    float3 band = lpHalf.rgb - lp.rgb;                      // detail around the cutoff scale
    float3 col;
    if (mode == 0) col = lp.rgb + band * res * 4.0;
    else if (mode == 1) col = abs(dry.rgb - lp.rgb + band * res * 4.0);
    else col = abs(band) * (2.0 + res * 6.0);
    return fx_out(dry, float4(max(col * level, 0.0), dry.a), c);
}

// ---------- Hue shift (pitch) ----------

fragment float4 fx_hue(FX_ARGS) {
    float pitchClass = fmod(round(g.note * 127.0), 12.0) / 12.0;
    float shift = p[0] / 360.0 + p[1] * pitchClass + p[4] * g.beat
                + p[5] / 360.0 * sin(g.beat * p[6] * TAU) + p[7] * in.uv.x + p[8] / 360.0 * g.pulse;
    float4 dry = src.sample(linearClamp, in.uv);
    float3 h = rgb2hsv(max(dry.rgb, 0.0));
    float3 col = hsv2rgb(float3(fract(h.x + shift), saturate(h.y * p[2]), h.z * p[3]));
    return fx_out(dry, float4(col, dry.a), c);
}

// ---------- Tremolo (strobe) ----------

fragment float4 fx_tremolo(FX_ARGS) {
    float rate = p[0], depth = p[1], duty = p[3], spread = p[5], gate = p[7], flash = p[8];
    int shape = int(p[2]), dir = int(p[6]);
    float pos = dir == 0 ? in.uv.x : (dir == 1 ? in.uv.y : length(in.p) * 0.5);
    float ph = g.beat * rate + p[4] - spread * pos;
    float f = fract(ph);
    float fw = max(fwidth(ph), 1e-4);
    float lfo;
    switch (shape) {
        case 0: lfo = 0.5 + 0.5 * cos(f * TAU); break;
        case 1: lfo = abs(f * 2.0 - 1.0); break;
        case 2: lfo = saturate((duty - f) / fw + 0.5); break;
        case 3: lfo = 1.0 - f; break;
        case 4: lfo = f; break;
        default: lfo = hash11(floor(ph) + 0.5); break;
    }
    float amp = (1.0 - depth * (1.0 - lfo)) * mix(1.0, saturate(g.pulse), gate);
    float4 dry = src.sample(linearClamp, in.uv);
    float fl = flash * g.pulse * g.pulse;
    float4 wet = float4(dry.rgb * amp + fl, max(dry.a * amp, fl));
    return fx_out(dry, wet, c);
}

// ---------- Glow (reverb) ----------

fragment float4 fx_glow(FX_ARGS) {
    float size = p[0], amount = p[1] * (1.0 + p[6] * g.pulse), thr = p[2], decay = p[3];
    float3 tint = mix(float3(1.0), hsv2rgb(float3(p[4], 0.8, 1.0)) * 1.5, p[5]);
    float4 dry = src.sample(linearClamp, in.uv);
    float2 r = float2(size / g.aspect, size);
    float rot = 0.3;   // fixed pattern: mip sampling already smooths, jitter only costs cache
    const int N = 12;
    // read a pre-shrunk mip level so few, cache-friendly taps cover a wide radius
    float lod = max(0.0, log2(size * g.res.y / sqrt(float(N)) * 0.7));
    float3 acc = 0.0;
    float ws = 0.0;
    float2 d = float2(cos(rot), sin(rot));
    const float2x2 golden = rot2(2.39996323);
    for (int i = 0; i < N; i++) {
        float rr = sqrt((float(i) + 0.5) / float(N));
        float w = exp(-3.0 * rr);                            // heavy centre, long tail
        float3 s = src.sample(mipClamp, in.uv + d * rr * r, level(lod)).rgb;
        float l = max3(s.r, s.g, s.b);
        acc += s * (max(l - thr, 0.0) / max(l, 1e-4)) * w;
        ws += w;
        d = golden * d;
    }
    float3 col = dry.rgb + acc / ws * amount * tint;
    if (decay > 0.001) {
        // tail: last frame, slightly spread, fading; max() keeps it from blowing up
        float3 tail = fx_disc(prev, in.uv, r * 0.12, 6, rot, 1.0).rgb * decay;
        col = max(col, tail);
    }
    return fx_out(dry, float4(col, dry.a), c);
}

