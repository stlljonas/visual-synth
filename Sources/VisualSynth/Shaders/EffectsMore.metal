// More effects: see the conventions in Common.metal.
// Helpers here are prefixed fm_ (this file is concatenated with the others).

#define FM_ARGS VOut in [[stage_in]], constant Globals& g [[buffer(0)]], \
    constant float* p [[buffer(1)]], constant FxCommon& c [[buffer(2)]], \
    texture2d<float> src [[texture(0)]], texture2d<float> prev [[texture(1)]]

/// Centred, aspect-correct point (like in.p) → texture uv.
inline float2 fm_uv(float2 q, float aspect) { return float2(q.x / aspect * 0.5 + 0.5, 0.5 - q.y * 0.5); }

/// 1 inside the 0…1 uv square, else 0.
inline float fm_inside(float2 uv) { return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0); }

/// Cheap hue rotation (turns) around the grey axis.
inline float3 fm_hue(float3 col, float turns) {
    float a = turns * TAU, ca = cos(a), sa = sin(a);
    const float3 k = float3(0.57735027);
    return col * ca + cross(k, col) * sa + k * dot(k, col) * (1.0 - ca);
}

/// Triangle wave 0→1→0 over one unit: seamless mirrored repeats.
inline float fm_tri(float t) { return 1.0 - abs(fract(t) * 2.0 - 1.0); }

inline float fm_max3(float3 v) { return max(v.x, max(v.y, v.z)); }

// ---------------------------------------------------------------- Polar Warp

fragment float4 fx_polar(FM_ARGS) {
    float mode = p[0], rep = max(p[1], 1.0), twist = p[2] + p[9] * g.pulse * 2.0, zoom = p[3];
    float spin = p[4], scroll = p[5], seam = p[8];
    float2 ctr = float2(p[6] * g.aspect, p[7]);
    float4 dry = src.sample(linearClamp, in.uv);
    float2 suv;
    if (mode < 1.5) {
        float2 q = in.p - ctr;
        float r = length(q) / zoom;
        float t = (atan2(q.y, q.x) / TAU + 0.5) * rep + twist * r + spin * g.beat * rep;
        float ang = seam < 0.5 ? fm_tri(t) : fract(t);
        float rad = r - scroll * g.beat;
        suv = mode < 0.5 ? float2(rad, ang) : float2(ang, 1.0 - rad);
    } else {
        // unroll: x = angle, y = radius (bottom = centre)
        float r = (1.0 - in.uv.y) * zoom * 1.2 + scroll * g.beat;
        r = fm_tri(r * 0.5) * 2.0;                       // bounce instead of wrapping
        float a = TAU * (in.uv.x * rep + spin * g.beat) + twist * r;
        suv = fm_uv(ctr + r * float2(cos(a), sin(a)), g.aspect);
    }
    float4 wet = src.sample(linearMirror, suv);
    return fx_out(dry, wet, c);
}

// ---------------------------------------------------------------- Multi-tap Delay

fragment float4 fx_multitap(FM_ARGS) {
    int n = int(p[0]);
    float2 off = float2(p[1] * 2.0 * g.aspect, p[2] * 2.0);
    float lscale = log(p[3]), rot = p[4] * PI / 180.0, decay = p[5], hue = p[6];
    float lfoShape = p[7], ph = fract(g.beat * p[8]);
    float lfo = lfoShape < 0.5 ? 0.0 : lfoShape < 1.5 ? sin(ph * TAU)
              : lfoShape < 2.5 ? ph * 2.0 - 1.0 : floor(ph * 4.0) / 3.0 * 2.0 - 1.0;
    float spread = 1.0 + p[9] * lfo + p[10] * g.pulse * 2.0;
    float combine = p[11];
    float4 dry = src.sample(linearClamp, in.uv);
    float4 acc = dry;
    float lvl = 1.0;
    for (int k = 1; k <= n; k++) {
        float kf = float(k) * spread;
        lvl *= decay;
        float2 q = rot2(-rot * kf) * (in.p - off * kf) * exp(-lscale * kf);
        float2 uv = fm_uv(q, g.aspect);
        float4 s = src.sample(linearClamp, uv) * (fm_inside(uv) * lvl);
        s.rgb = fm_hue(s.rgb, hue * float(k));
        s = max(s, 0.0);
        if (combine < 0.5)      acc = max(acc, s);
        else if (combine < 1.5) acc += s;
        else                    acc = 1.0 - (1.0 - saturate(acc)) * (1.0 - saturate(s));
    }
    return fx_out(dry, acc, c);
}

// ---------------------------------------------------------------- Sidechain Duck

fragment float4 fx_duck(FM_ARGS) {
    float source = p[0], depth = p[1], rate = p[2], shape = p[3];
    float darken = p[4], shrink = p[5], blur = p[6], desat = p[7], twist = p[8];
    float beatEnv = 1.0 - fract(g.beat * rate);
    float env = source < 0.5 ? g.pulse : source < 1.5 ? beatEnv : source < 2.5 ? max(g.pulse, beatEnv) : g.gate;
    float d = depth * pow(saturate(env), shape);

    float4 dry = src.sample(linearClamp, in.uv);
    float s = 1.0 - d * shrink * 0.6;
    float2 q = rot2(d * twist * PI * 0.5) * in.p / s;
    float2 uv = fm_uv(q, g.aspect);
    float4 col = src.sample(linearClamp, uv);
    float br = d * blur * 0.03;
    if (br > 1e-4) {
        float2 rr = float2(br / g.aspect, br);
        for (int i = 0; i < 8; i++) {
            float a = float(i) * (TAU / 8.0) + 0.4;
            col += src.sample(linearClamp, uv + float2(cos(a), sin(a)) * rr);
        }
        col /= 9.0;
    }
    col *= fm_inside(uv);
    col.rgb = mix(col.rgb, float3(luma(col.rgb)), d * desat);
    col.rgb *= 1.0 - d * darken;
    return fx_out(dry, col, c);
}

// ---------------------------------------------------------------- Freeze / Hold

fragment float4 fx_freeze(FM_ARGS) {
    float mode = p[0], len = p[1], amount = p[2], live = p[3], fade = p[4], combine = p[5];
    float drift = p[6], zoom = p[7];
    float hold;
    if (mode < 0.5)      hold = smoothstep(0.1, 0.6, g.gate);
    else if (mode < 1.5) hold = 1.0;
    else if (mode < 2.5) hold = smoothstep(0.1, 0.3, g.pulse);
    else {
        float beats = fract(g.beat / len) * len;        // beats since this stutter started
        float frameBeats = g.dt * g.bpm / 60.0;
        hold = step(frameBeats * 1.001, beats);          // refresh on the first frame of each slice
    }
    hold *= amount;
    float4 dry = src.sample(linearClamp, in.uv);
    float2 q = in.p / (1.0 + zoom * g.dt * 0.6) + float2(0.0, drift * g.dt * 0.5);
    float2 uv = fm_uv(q, g.aspect);
    float4 held = prev.sample(linearClamp, uv) * (fm_inside(uv) * exp(-fade * g.dt));
    float4 frozen = combine < 0.5 ? held : combine < 1.5 ? max(held, dry * live) : held + dry * live;
    frozen = min(frozen, 4.0);
    return fx_out(dry, mix(dry, frozen, hold), c);
}

// ---------------------------------------------------------------- Neon Edges

inline float fm_l(texture2d<float> t, float2 uv) { return luma(t.sample(linearClamp, uv).rgb); }

/// Sobel gradient of luma at uv with sample spacing d (uv units). Centre not needed.
inline float2 fm_sobel(texture2d<float> t, float2 uv, float2 d) {
    float tl = fm_l(t, uv + float2(-d.x, -d.y)), tc = fm_l(t, uv + float2(0, -d.y)), tr = fm_l(t, uv + float2(d.x, -d.y));
    float ml = fm_l(t, uv + float2(-d.x, 0)),                                     mr = fm_l(t, uv + float2(d.x, 0));
    float bl = fm_l(t, uv + float2(-d.x, d.y)), bc = fm_l(t, uv + float2(0, d.y)), br = fm_l(t, uv + float2(d.x, d.y));
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (tl + 2.0 * tc + tr) - (bl + 2.0 * bc + br);   // + = brighter upwards
    return float2(gx, gy) * 0.25;
}

fragment float4 fx_edges(FM_ARGS) {
    float thick = p[0], thresh = p[1], gain = p[2], glow = p[3], fill = p[4], cmode = p[5];
    float hue = p[6] + p[7] * g.beat, kick = p[8];
    float4 dry = src.sample(linearClamp, in.uv);
    float2 px = thick / g.res;
    float2 gr = fm_sobel(src, in.uv, px);
    float m = length(gr);
    float e = saturate((m - thresh) / max(1.0 - thresh, 1e-3) * gain);
    float halo = 0.0;
    if (glow > 0.001) {
        float2 g2 = fm_sobel(src, in.uv, px * 4.0);
        halo = saturate(length(g2) * gain) * glow * 0.35;
    }
    float3 col;
    if (cmode < 0.5)      col = hsv2rgb(float3(fract(atan2(gr.y, gr.x) / TAU + hue), 0.85, 1.0));
    else if (cmode < 1.5) col = dry.rgb / max(fm_max3(dry.rgb), 0.05);
    else if (cmode < 2.5) col = hsv2rgb(float3(fract(hue), 0.85, 1.0));
    else                  col = float3(1.0);
    if (cmode > 0.5 && cmode < 1.5) {
        // source colour is ambiguous on the dark side of an edge: use the brighter neighbour
        float2 n = normalize(gr + 1e-6) * float2(1, -1) * px * 1.5;
        float3 b = src.sample(linearClamp, in.uv + n).rgb;
        col = b / max(fm_max3(b), 0.05);
    }
    float k = (e + halo) * (1.0 + kick * g.pulse * 1.5);
    float4 wet = float4(dry.rgb * fill + col * k, max(dry.a * fill, saturate(k)));
    return fx_out(dry, wet, c);
}

// ---------------------------------------------------------------- Smear

fragment float4 fx_smear(FM_ARGS) {
    float len = p[0] * (1.0 + p[8] * g.pulse * 2.0);
    float ang = (p[1] + p[6] * g.beat * 360.0 + p[7] * sin(g.beat * TAU * 0.25)) * PI / 180.0;
    int n = int(p[2]);
    float thresh = p[3], decay = p[4], mode = p[5], tint = p[9];
    float2 duv = float2(cos(ang) / g.aspect, -sin(ang)) * 0.5 * len;
    float4 dry = src.sample(linearClamp, in.uv);
    float4 acc = dry;
    float best = luma(dry.rgb);
    float both = step(1.5, mode);
    for (int i = 1; i <= n; i++) {
        float t = float(i) / float(n);
        float tt = both > 0.5 ? (t * 2.0 - 1.0 - 0.5 / float(n)) : t;   // -1…1 when smearing both ways
        float4 s = src.sample(linearClamp, in.uv - duv * tt);
        float l = luma(s.rgb);
        if (l < thresh) continue;
        if (abs(tint) > 1e-4) s.rgb = fm_hue(s.rgb, tint * abs(tt));
        if (mode > 0.5 && mode < 1.5) {
            // pixel sort: the brightest sample upstream wins, no fade
            if (l > best) { best = l; acc = s; }
        } else {
            acc = max(acc, s * (1.0 - decay * abs(tt)));
        }
    }
    return fx_out(dry, acc, c);
}

// ---------------------------------------------------------------- Melt / Datamosh

fragment float4 fx_melt(FM_ARGS) {
    float amount = p[0] * (1.0 + p[10] * g.pulse * 3.0), decay = p[1], gradK = p[2], noiseK = p[3];
    float nscale = p[4], speed = p[5], gravity = p[6], blocks = p[7], bsize = p[8], hue = p[9], combine = p[11];
    float2 px = 1.0 / g.res;
    float4 dry = src.sample(linearClamp, in.uv);

    float2 disp = float2(0.0, gravity);
    if (abs(gradK) > 1e-3) {
        float2 o = px * 3.0;
        float lx = fm_l(prev, in.uv + float2(o.x, 0)) - fm_l(prev, in.uv - float2(o.x, 0));
        float ly = fm_l(prev, in.uv + float2(0, o.y)) - fm_l(prev, in.uv - float2(0, o.y));
        float2 gr = float2(lx, ly);
        disp += gr / max(length(gr), 0.25) * gradK;       // ≤ 1 px per unit: never explodes
    }
    if (noiseK > 1e-3) {
        float2 np = in.p * nscale + float2(g.beat * speed, -g.beat * speed * 0.7);
        float a = vnoise(np) * TAU * 2.0;
        disp += float2(cos(a), sin(a)) * noiseK;
    }
    if (blocks > 1e-3) {
        float2 id = floor(in.uv * g.res / bsize);
        float2 v = hash22(id + fract(g.trigger * 0.618) * 97.0) * 2.0 - 1.0;
        v *= step(0.35, hash21(id * 1.7 + g.trigger));     // some blocks stand still, like real P-frames
        disp = mix(disp, v * 2.0, blocks);
    }
    float2 uv = in.uv - disp * amount * px;
    float4 fb = prev.sample(linearClamp, uv) * decay;
    if (abs(hue) > 1e-5) fb.rgb = fm_hue(fb.rgb, hue);
    fb = clamp(fb, 0.0, 1.5);

    float4 wet;
    if (combine < 0.5)      wet = max(dry, fb);
    else if (combine < 1.5) wet = min(dry + fb, 2.0);
    else                    wet = mix(fb, dry, saturate(fm_max3(dry.rgb) * 6.0));
    return fx_out(dry, wet, c);
}

// ---------------------------------------------------------------- CRT / Scanlines

fragment float4 fx_crt(FM_ARGS) {
    float lines = p[0], scan = p[1], maskType = p[2], maskK = p[3], maskSize = p[4], curve = p[5];
    float vig = p[6], bloom = p[7], bleed = p[8], flick = p[9], roll = p[10], bright = p[11];

    // curved glass
    float2 q = in.uv * 2.0 - 1.0;
    q *= 1.0 + curve * (q.yx * q.yx);
    float2 uv = q * 0.5 + 0.5;
    float2 edgePx = min(uv, 1.0 - uv) * g.res;
    float frame = saturate(min(edgePx.x, edgePx.y) + 0.5);

    // note jitter: a few lines slip sideways
    float line = floor(uv.y * lines);
    float jit = hash21(float2(line, floor(g.trigger))) ;
    uv.x += step(0.85, jit) * (jit - 0.92) * 0.08 * flick * g.pulse;

    float2 bx = float2(bleed / g.res.x, 0.0);
    float3 col;
    col.r = src.sample(linearClamp, uv - bx).r;
    col.g = src.sample(linearClamp, uv).g;
    col.b = src.sample(linearClamp, uv + bx).b;
    if (bloom > 0.001) {
        float2 r = float2(7.0 / g.res.y / g.aspect, 7.0 / g.res.y) * (g.res.y / 1000.0);
        float3 b = src.sample(linearClamp, uv + r * float2(1, 1)).rgb + src.sample(linearClamp, uv + r * float2(-1, 1)).rgb
                 + src.sample(linearClamp, uv + r * float2(1, -1)).rgb + src.sample(linearClamp, uv + r * float2(-1, -1)).rgb;
        col += max(b * 0.25 - 0.1, 0.0) * bloom * 0.6;
    }

    // scanlines (fade out when they get finer than the pixels)
    float y = fract(uv.y * lines);
    float beam = sin(PI * y);
    beam *= beam;
    float sAA = saturate(1.5 - fwidth(uv.y * lines) * 1.6);
    float lum = saturate(luma(col));
    float sl = mix(1.0, mix(beam, sqrt(beam), lum), scan * sAA);   // bright lines bloom wider
    col *= sl;

    // phosphor mask, in screen pixels
    if (maskType < 2.5 && maskK > 0.001) {
        float2 mp = in.pos.xy / maskSize;
        float cx = mp.x;
        if (maskType > 1.5) cx += floor(mp.y) * 1.5;                   // dots: shift each row
        float sub = fmod(floor(cx), 3.0);
        float3 m = float3(sub < 0.5, sub > 0.5 && sub < 1.5, sub > 1.5);
        if (maskType > 0.5 && maskType < 1.5) {                        // slot: dark gaps, staggered per triad
            float tri = floor(cx / 3.0);
            float gap = step(fract(mp.y / 4.0 + fmod(tri, 2.0) * 0.5), 0.25);
            m *= 1.0 - gap;
        }
        col *= mix(float3(1.0), m * 2.2, maskK);
    }

    // roll bar once per bar, vignette, flicker
    float pos = fract(g.beat * 0.25) * 1.4 - 0.2;
    col *= 1.0 + roll * 0.6 * exp(-pow((uv.y - pos) * 9.0, 2.0));
    float2 vq = uv * (1.0 - uv);
    col *= mix(1.0, saturate(pow(vq.x * vq.y * 16.0, 0.3)), vig);
    col *= 1.0 + flick * g.pulse * (hash11(floor(g.time * 40.0)) - 0.35) * 0.8;
    col *= bright * frame;
    float4 dry = src.sample(linearClamp, in.uv);
    return fx_out(dry, float4(max(col, 0.0), dry.a), c);
}

// ---------------------------------------------------------------- Halftone

/// One dot screen: coverage (0…1) at pixel `pos` for the value read at the cell centre.
/// Returns (coverage) and writes the sampled colour.
inline float fm_screen(texture2d<float> t, float2 pos, float2 res, float cell, float ang, float shape,
                       float gain, float soft, int channel, thread float3& sampled) {
    float2x2 r = rot2(ang);
    float2 qq = (r * pos) / cell;
    float2 id = floor(qq) + 0.5;
    float2 f = qq - id;
    float2 centre = transpose(r) * (id * cell);
    sampled = t.sample(linearClamp, centre / res).rgb;
    float v = channel < 0 ? luma(sampled) : sampled[channel];
    v = saturate(v);
    float d;
    if (shape < 0.5)      d = length(f) - 0.62 * sqrt(v) * gain;
    else if (shape < 1.5) d = max(abs(f.x), abs(f.y)) - 0.5 * sqrt(v) * gain;
    else                  d = abs(f.y) - 0.5 * v * gain;
    float w = 0.75 / cell + soft * 0.35;                // one pixel in cell units: crisp, no fwidth seams
    return 1.0 - smoothstep(-w, w, d);
}

fragment float4 fx_halftone(FM_ARGS) {
    float cell = p[0] * (g.res.y / 1000.0) * (1.0 + p[6] * g.pulse);
    float ang = (p[1] + p[5] * g.beat * 360.0) * PI / 180.0;
    float mode = p[2], gain = p[3], colK = p[4], shape = p[7], soft = p[8];
    float4 dry = src.sample(linearClamp, in.uv);
    float2 pos = in.uv * g.res;
    float3 col, s;
    cell = max(cell, 2.0);
    if (mode < 0.5) {
        float cov = fm_screen(src, pos, g.res, cell, ang, shape, gain, soft, -1, s);
        float3 tint = mix(float3(1.0), s / max(fm_max3(s), 1e-3), colK);
        col = tint * cov;
    } else if (mode < 1.5) {
        for (int ch = 0; ch < 3; ch++)
            col[ch] = fm_screen(src, pos, g.res, cell, ang + float(ch) * 0.5236, shape, gain, soft, ch, s);
    } else {
        // CMY inks on white paper: ink coverage follows 1 - channel
        float3 ink;
        float angs[3] = { 0.2618, 1.309, 0.0 };
        for (int ch = 0; ch < 3; ch++) {
            float2x2 r = rot2(ang + angs[ch]);
            float2 qq = (r * pos) / cell;
            float2 id = floor(qq) + 0.5;
            float2 f = qq - id;
            float3 smp = src.sample(linearClamp, (transpose(r) * (id * cell)) / g.res).rgb;
            float v = 1.0 - saturate(smp[ch]);
            float d = shape < 0.5 ? length(f) - 0.62 * sqrt(v) * gain
                    : shape < 1.5 ? max(abs(f.x), abs(f.y)) - 0.5 * sqrt(v) * gain : abs(f.y) - 0.5 * v * gain;
            float w = 0.75 / cell + soft * 0.35;
            ink[ch] = 1.0 - smoothstep(-w, w, d);
        }
        col = 1.0 - ink;
    }
    return fx_out(dry, float4(col, 1.0), c);
}

// ---------------------------------------------------------------- Solarize / Invert

fragment float4 fx_solarize(FM_ARGS) {
    float amount = p[0], t = p[1] + p[2] * sin(g.beat * p[3] * TAU), spread = p[4];
    float inv = saturate(p[5] + p[6] * g.pulse);
    float steps = p[7], gain = p[8];
    float4 dry = src.sample(linearClamp, in.uv);
    float3 x = saturate(dry.rgb);
    float3 th = clamp(t + spread * float3(-1.0, 0.0, 1.0), 0.03, 0.97);
    float3 tent = select((1.0 - x) / (1.0 - th), x / th, x < th);     // peaks at the threshold
    float3 y = mix(x, tent, amount) * gain;
    y = mix(y, 1.0 - saturate(y), inv);
    if (steps > 0.5) y = floor(saturate(y) * steps + 0.5) / steps;
    return fx_out(dry, float4(y, max(dry.a, inv)), c);
}

// ---------------------------------------------------------------- Lens / Fisheye

fragment float4 fx_lens(FM_ARGS) {
    float k = p[0] * (1.0 + p[7] * sin(g.beat * p[6] * TAU)) + p[5] * g.pulse * 0.8;
    float zoom = p[1], ca = p[2], edge = p[8], vig = p[9];
    float2 ctr = float2(p[3] * g.aspect, p[4]);
    float4 dry = src.sample(linearClamp, in.uv);
    float2 q = in.p - ctr;
    float r2 = dot(q, q) / (g.aspect * g.aspect + 1.0);   // 1 at the corners
    float f = max(1.0 + k * r2, 0.1) / zoom;
    float3 fc = f * (1.0 + ca * 0.06 * r2 * float3(1.0, 0.0, -1.0));
    float2 ur = fm_uv(ctr + q * fc.r, g.aspect), ug = fm_uv(ctr + q * fc.g, g.aspect), ub = fm_uv(ctr + q * fc.b, g.aspect);
    float4 col;
    if (edge < 0.5) {
        col = float4(src.sample(linearClamp, ur).r * fm_inside(ur), src.sample(linearClamp, ug).g * fm_inside(ug),
                     src.sample(linearClamp, ub).b * fm_inside(ub), dry.a);
    } else if (edge < 1.5) {
        col = float4(src.sample(linearMirror, ur).r, src.sample(linearMirror, ug).g, src.sample(linearMirror, ub).b, dry.a);
    } else {
        col = float4(src.sample(linearRepeat, ur).r, src.sample(linearRepeat, ug).g, src.sample(linearRepeat, ub).b, dry.a);
    }
    col.rgb *= 1.0 - vig * smoothstep(0.2, 1.2, r2);
    return fx_out(dry, col, c);
}
