// Generators: see the conventions in Common.metal.

fragment float4 gen_bars(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                         constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float count = p[0], width = p[1], speed = p[2], angle = p[3] * PI / 180.0;
    float soft = p[4], pulseW = p[5], rainbow = p[6];
    float2 q = rot2(angle) * in.p;
    float x = q.x / (2.0 * g.aspect) * count - g.beat * speed;
    float w = saturate(width + pulseW * g.pulse * (1.0 - width));
    float cell = floor(x - w * 0.5 + 0.5);
    float d = abs(fract(x - w * 0.5 + 0.5) - 0.5) - w * 0.5;  // distance to bar edge, in periods
    float mask = aa_fill(d, soft * 0.5);
    return gen_out(mask, rainbow * cell / max(count, 1.0), g, c);
}

// ---------- generator helpers (prefixed gn_ so they can't clash with other shader files) ----------

/// Size of one pixel in `in.p` units.
inline float gn_px(constant Globals& g) { return 2.0 / g.res.y; }

/// Antialiased fill of a distance `d` (inside < 0) whose pixel size `px` is known.
/// Unlike aa_fill it doesn't use fwidth, so it stays clean where `d` jumps (cell borders).
inline float gn_fill(float d, float px, float soft) {
    float w = px * 0.75 + soft;
    return 1.0 - smoothstep(-w, w, d);
}

/// Periodic band: `x` in periods, lit share `w` centred on k + 0.5. `fw` = periods per pixel.
/// Fades to the average coverage when the period gets close to a pixel (no moiré / shimmer).
inline float gn_band(float x, float w, float fw, float soft) {
    float d = abs(fract(x) - 0.5) - w * 0.5;
    float e = fw * 0.75 + soft * 0.5 + 1e-5;
    float m = 1.0 - smoothstep(-e, e, d);
    return mix(m, w, smoothstep(0.2, 0.5, fw));
}

/// fwidth of atan2(p.y, p.x) without the jump at the branch cut.
inline float gn_fw_angle(float2 p, float px) {
    return px * (abs(p.x) + abs(p.y)) / max(dot(p, p), px * px);
}

/// "Polygon radius": equals r on the regular n-gon of circumradius r (vertex on +x).
inline float gn_poly_rho(float2 p, float n) {
    float s = TAU / n;
    float a = atan2(p.y, p.x);
    a -= s * floor(a / s + 0.5);
    return length(p) * cos(a) / cos(PI / n);
}

/// Soft XOR of two coverages.
inline float gn_xor(float a, float b) { return a + b - 2.0 * a * b; }

inline float gn_seg2(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    float2 d = pa - ba * h;
    return dot(d, d);
}

// ---------- shapes: rotating regular polygons ----------

fragment float4 gen_shapes(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                           constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float sides = p[0], layout = p[1], count = max(p[2], 1.0), size = p[3];
    float style = p[4], thick = p[5], spin = p[6], alt = p[7], stagger = p[8];
    float orbit = p[9], nest = max(p[10], 1.0), pulse = p[11], jump = p[12], rainbow = p[13], soft = p[14];
    float flow = p[15];
    float px = gn_px(g);

    float2 q;         // local coords, the cell spans -0.5…0.5
    float cell;       // cell size in in.p units
    float idx, parity;
    if (layout < 0.5) {                       // grid
        cell = 2.0 / count;
        float2 u = in.p / cell;
        u.y += 0.5 * fmod(count, 2.0);            // rows fill the height exactly
        u.x += 0.5;                               // a column centred on x = 0
        float2 id = floor(u);
        q = fract(u) - 0.5;
        idx = hash21(id + 3.1);
        parity = fmod(abs(id.x + id.y), 2.0);
        float diag = id.x + id.y;
        q = rot2(TAU * stagger * diag * 0.125) * q;
    } else if (layout < 1.5) {                // ring
        float R = 0.62;
        float2 pp = rot2(TAU * orbit * g.beat) * in.p;
        float s = TAU / count;
        float a = atan2(pp.y, pp.x);
        float k = floor(a / s + 0.5);
        float2 l = rot2(-k * s) * pp - float2(R, 0);
        cell = count < 1.5 ? 0.9 : min(2.0 * R * sin(PI / count), 0.9);
        q = l / cell;
        float kk = fmod(k + count, count);
        idx = kk / count;
        parity = fmod(kk, 2.0);
        q = rot2(TAU * stagger * kk / count) * q;
    } else {                                  // single, centred
        cell = 2.0;
        q = in.p / cell;
        idx = 0.0;
        parity = 0.0;
    }
    float dir = mix(1.0, parity > 0.5 ? -1.0 : 1.0, alt);
    float rot = TAU * (spin * g.beat + jump * hash11(g.trigger * 0.618 + 0.1));
    q = rot2(rot * dir) * q;

    float r = 0.5 * size * (1.0 + pulse * g.pulse * 0.6);
    float ht = thick * r * 0.5 / sqrt(nest);   // outline half thickness
    r = min(r, 0.49 - (style < 0.5 ? ht : 0.0));
    float off = 1.0 - fract(-g.beat * flow);  // nested copies flow outwards; 1 when still
    if (flow != 0.0) r *= nest / (nest + 1.0);
    float pxl = px / cell;                    // pixel in local units
    float k = cos(PI / sides);                // rho → distance
    float rho = gn_poly_rho(q, sides);

    float mask;
    float sf = soft * 0.1;
    if (style < 0.5) {                        // outlines, nested copies inside
        float x = rho * nest / r - off;       // copies sit at x = 0 … nest
        float j = clamp(floor(x + 0.5), 0.0, nest);
        float d = abs(x - j) * r / nest * k;
        float fade = j < 0.5 ? off : (j > nest - 0.5 ? 1.0 - off : 1.0);
        mask = gn_fill(d - ht, pxl, sf) * fade;
    } else {                                  // filled (alternating bands when nested)
        mask = gn_fill((rho - r) * k, pxl, sf);
        if (nest > 1.5) {
            float x = rho * nest / r;
            mask *= gn_band(x - 0.25 - off, 0.5, pxl * nest / (r * k), sf * nest / r);
        }
    }
    return gen_out(mask, rainbow * idx, g, c);
}

// ---------- grid: lattice of dots / squares, sized by a travelling wave ----------

fragment float4 gen_grid(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                         constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float rows = max(p[0], 1.0), shape = p[1], size = p[2], wave = p[3], freq = p[4], speed = p[5];
    float depth = p[6], shift = p[7], spin = p[8], pulse = p[9], rainbow = p[10], soft = p[11];
    float scroll = p[12], lw = p[13];
    float px = gn_px(g);
    float cell = 2.0 / rows;
    float2 off = float2(g.beat * scroll, 0.5 * fmod(rows, 2.0));
    float2 u = in.p / cell + off + float2(0.5, 0.0);
    float2 id = floor(u);
    float2 q = fract(u) - 0.5;
    float2 ctr = (id + 0.5 - off - float2(0.5, 0.0)) * cell;   // cell centre in in.p units

    float ph;
    if (wave < 0.5)      ph = length(ctr) * freq - g.beat * speed;                     // radial
    else if (wave < 1.5) ph = ctr.x * 0.5 * freq - g.beat * speed;                     // horizontal
    else if (wave < 2.5) ph = (ctr.x + ctr.y) * 0.3535 * freq - g.beat * speed;         // diagonal
    else                 ph = vnoise(ctr * freq * 1.5 + float2(g.beat * speed, 0.0)) * 2.0 + g.beat * speed * 0.25; // noise
    float w = 0.5 + 0.5 * sin(TAU * ph);

    float r = 0.5 * size * mix(1.0, w, depth) * (1.0 + pulse * g.pulse);
    float sh = shift * 0.5;
    q -= sh * float2(cos(TAU * ph), sin(TAU * ph));
    r = min(r, 0.48 - sh);
    q = rot2(TAU * spin * g.beat) * q;

    float d;
    float t = lw * r;                        // stroke half width for crosses / rings
    if (shape < 0.5) {                       // dots
        d = length(q) - r;
    } else if (shape < 1.5) {                // squares
        float2 b = abs(q) - r * 0.8;
        d = length(max(b, 0.0)) + min(max(b.x, b.y), 0.0);
    } else if (shape < 2.5) {                // diamonds
        d = (abs(q.x) + abs(q.y) - r) * 0.7071;
    } else if (shape < 3.5) {                // crosses
        float2 a = abs(q);
        float2 b1 = a - float2(r, t), b2 = a - float2(t, r);
        float d1 = length(max(b1, 0.0)) + min(max(b1.x, b1.y), 0.0);
        float d2 = length(max(b2, 0.0)) + min(max(b2.x, b2.y), 0.0);
        d = min(d1, d2);
    } else {                                 // rings
        d = abs(length(q) - r + t) - t;
    }
    float mask = gn_fill(d, px / cell, soft * 0.1) * smoothstep(0.0, 0.02, r);
    return gen_out(mask, rainbow * w, g, c);
}

// ---------- rings: concentric rings streaming out of the centre ----------

fragment float4 gen_rings(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                          constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float count = p[0], width = p[1], speed = p[2], tunnel = p[3], shape = p[4], sides = p[5];
    float spin = p[6], twist = p[7], wobble = p[8], lobes = p[9], wspeed = p[10];
    float pulse = p[11], rainbow = p[12], soft = p[13], hole = p[14];
    float2 q = rot2(TAU * spin * g.beat) * in.p;
    float r0 = length(q);
    q = rot2(twist * log(max(r0, 1e-3))) * q;
    float rho = shape < 0.5 ? r0 : gn_poly_rho(q, sides);
    float a = atan2(q.y, q.x);
    rho *= 1.0 + wobble * sin(lobes * a + TAU * wspeed * g.beat);
    rho = max(rho, 1e-4);
    float u = mix(rho * count / 1.5, (log(rho) + 0.5) * count * 0.25, tunnel);
    float x = u - g.beat * speed;
    float fw = fwidth(x);
    float w = saturate(width + pulse * g.pulse * (1.0 - width) * 0.6);
    float mask = gn_band(x, w, fw, soft) * smoothstep(hole * 0.5, hole, r0);
    return gen_out(mask, rainbow * floor(x) / max(count, 1.0), g, c);
}

// ---------- waves: stacked oscilloscope lines ----------

inline float gn_wave(float t, float shape, float harm, float seed) {
    float w;
    float s = sin(TAU * t);
    if (shape < 0.5)      w = s;
    else if (shape < 1.5) w = asin(s * 0.999) * (2.0 / PI);                        // triangle
    else if (shape < 2.5) w = tanh(s * 5.0);                                       // square (soft corners)
    else if (shape < 3.5) w = atan(0.9 * sin(TAU * t) / (1.0 - 0.9 * cos(TAU * t))) / asin(0.9); // saw (soft)
    else                  w = vnoise(float2(t * 2.0, seed * 7.31)) * 2.0 - 1.0;   // noise
    return w + harm * 0.4 * sin(TAU * (3.0 * t + 0.13 * seed));
}

fragment float4 gen_waves(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                          constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    int n = int(clamp(p[0], 1.0, 32.0));
    float shape = p[1], freq = p[2], amp = p[3], speed = p[4], thick = p[5], spread = p[6];
    float shift = p[7], harm = p[8], pulseAmp = p[9], pitch = p[10], taper = p[11];
    float soft = p[12], rainbow = p[13];
    float px = gn_px(g);
    freq *= exp2((g.note - 0.5) * 4.0 * pitch);
    float xs = in.p.x / (2.0 * g.aspect);                    // -0.5 … 0.5 across the screen
    float env = mix(1.0, sin(PI * saturate(xs + 0.5)), taper);
    float A = amp * (1.0 + pulseAmp * g.pulse) * env;
    float reach = A * (1.0 + harm * 0.4) + thick + soft * 0.1 + 4.0 * px;
    float eps = 0.002;
    float best = 0.0, hue = 0.0;
    for (int i = 0; i < n; i++) {
        float fi = float(i);
        float y0 = n == 1 ? 0.0 : spread * 0.9 * (2.0 * (fi + 0.5) / float(n) - 1.0);
        float dy = in.p.y - y0;
        if (abs(dy) > reach) continue;
        float t = xs * freq + g.beat * speed + fi * shift;
        float f0 = A * gn_wave(t, shape, harm, fi);
        float dt = eps / (2.0 * g.aspect) * freq;
        float slope = A * (gn_wave(t + dt, shape, harm, fi) - gn_wave(t - dt, shape, harm, fi)) / (2.0 * eps);
        float d = abs(dy - f0) / sqrt(1.0 + slope * slope);
        float m = gn_fill(d - thick, px, soft * 0.1);
        if (m > best) { best = m; hue = fi / float(n); }
    }
    return gen_out(best, rainbow * hue, g, c);
}

// ---------- spokes: rotating sunburst / spiral arms, optionally cut into dashes ----------

fragment float4 gen_spokes(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                           constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float count = max(p[0], 1.0), width = p[1], speed = p[2], twist = p[3];
    float dashes = p[4], dspeed = p[5], dwidth = p[6], hole = p[7], counter = p[8];
    float pulse = p[9], jump = p[10], rainbow = p[11], soft = p[12];
    float px = gn_px(g);
    float2 q = in.p;
    float r = max(length(q), 1e-4);
    float lr = log(r);
    float a = atan2(q.y, q.x) / TAU;                          // turns
    float fa = gn_fw_angle(q, px) / TAU;                       // turns per pixel
    float fr = gn_fw_angle(q, px);                             // |grad log r| per pixel (same magnitude)
    float rot = speed * g.beat + jump * hash11(g.trigger * 0.618 + 0.3);
    float w = saturate(width + pulse * g.pulse * (1.0 - width) * 0.7);
    float x1 = (a - rot) * count + twist * lr;
    float fw = fa * count + abs(twist) * fr;
    float m = gn_band(x1, w, fw, soft);
    if (counter > 0.0) {
        float x2 = (a + rot) * count - twist * lr;
        m = mix(m, gn_xor(m, gn_band(x2, w, fw, soft)), counter);
    }
    if (dashes > 0.5) {
        float y = lr * dashes * 0.5 - g.beat * dspeed;
        m *= gn_band(y, dwidth, fr * dashes * 0.5, soft);
    }
    m *= 1.0 - gn_fill(r - hole, px, 0.0);
    return gen_out(m, rainbow * fract(floor(x1) / count), g, c);
}

// ---------- checker: checkerboard / stripes / grid lines, rotating & breathing, with a moiré layer ----------

inline float gn_pattern(float2 q, float pattern, float w, float2 fw, float soft) {
    float bx = gn_band(q.x, w, fw.x, soft);
    float by = gn_band(q.y, w, fw.y, soft);
    if (pattern < 0.5) return gn_xor(bx, by);                  // checker
    if (pattern < 1.5) return bx;                              // stripes
    return bx + by - bx * by;                                  // grid lines
}

fragment float4 gen_checker(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                            constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float scale = p[0], pattern = p[1], width = p[2], rotSpeed = p[3], angle = p[4] * PI / 180.0;
    float breathe = p[5], brate = p[6], sx = p[7], sy = p[8], warp = p[9], wfreq = p[10];
    float moire = p[11], mangle = p[12] * PI / 180.0, mscale = p[13], kick = p[14], soft = p[15];
    float px = gn_px(g);
    float zoom = scale * (1.0 + breathe * 0.5 * sin(TAU * brate * g.beat)) / (1.0 + kick * g.pulse * 0.5);
    float rot = angle + TAU * rotSpeed * g.beat;
    float2 pp = in.p;
    if (warp > 0.0) {
        pp += warp * 0.15 * float2(sin(wfreq * pp.y * PI + TAU * 0.25 * g.beat),
                                   sin(wfreq * pp.x * PI - TAU * 0.25 * g.beat));
    }
    float2 scrollv = float2(sx, sy) * g.beat;
    float m;
    if (pattern > 2.5) {                                       // polar: sectors × log rings
        float r = max(length(pp), 1e-4);
        float n = max(2.0, 2.0 * round(scale * 0.5));          // even sector count: seamless checker
        float2 q = float2(atan2(pp.y, pp.x) / TAU * n - rot / TAU * n,
                          log(r) * n / TAU - g.beat * sy * 2.0 + scrollv.x);
        float f = gn_fw_angle(pp, px) * n / TAU;
        m = gn_xor(gn_band(q.x, width, f, soft), gn_band(q.y, width, f, soft));
        if (moire > 0.0) {
            float2 q2 = float2(atan2(pp.y, pp.x) / TAU * n + rot / TAU * n, log(r) * n / TAU * mscale);
            m = mix(m, gn_xor(m, gn_xor(gn_band(q2.x, width, f, soft), gn_band(q2.y, width, f * mscale, soft))), moire);
        }
    } else {
        float2 q = rot2(rot) * pp * zoom * 0.5 + scrollv;
        float2 fw = fwidth(q);
        m = gn_pattern(q, pattern, width, fw, soft);
        if (moire > 0.0) {
            float2 q2 = rot2(rot + mangle) * pp * zoom * 0.5 * mscale + scrollv;
            m = mix(m, gn_xor(m, gn_pattern(q2, pattern, width, fwidth(q2), soft)), moire);
        }
    }
    return gen_out(m, 0.0, g, c);
}

// ---------- stars: particles flying towards the viewer (layers of hashed cells, no buffers) ----------

fragment float4 gen_stars(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                          constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    int layers = int(clamp(p[0], 1.0, 16.0));
    float cells = p[1], speed = p[2], size = p[3], streak = p[4], fill = p[5];
    float twinkle = p[6], spin = p[7], pstreak = p[8], psize = p[9], shape = p[10];
    float2 ctr = float2(p[11], p[12]);
    float rainbow = p[13];
    float px = gn_px(g);
    float2 pp = rot2(TAU * spin * g.beat) * (in.p - ctr);
    float best = 0.0, hue = 0.0;
    float nl = float(layers);
    float trail = (streak + pstreak * g.pulse) * 0.25 * sign(speed);
    for (int i = 0; i < layers; i++) {
        float t = g.beat * speed + float(i) / nl;
        float z = fract(t);                                  // 0 far … 1 near
        float cyc = floor(t);
        float depth = 1.0 - z * 0.88;
        float2 q = pp * depth * cells;                        // this layer's world coords
        float2 id = floor(q);
        float seed = cyc * 17.0 + float(i) * 131.0;
        float2 h = hash22(id + seed * 0.731);
        if (hash21(id + seed * 1.37 + 5.1) > fill) continue;
        float2 s = id + 0.5 + (h - 0.5) * 0.6;                // star position
        float rad = min(0.025 + 0.12 * size * (1.0 + psize * g.pulse), 0.18);
        // trail: where the star was a moment ago (further away = closer to the centre)
        float ratio = depth / (depth + abs(trail) * 0.5);
        float2 tail = s * (trail >= 0.0 ? ratio : 1.0 / ratio);
        // keep the trail inside this cell (no neighbour lookups): shorten it, don't bend it
        float2 dv = tail - s;
        float2 lim = select(id + 1.0 - rad, id + rad, dv < 0.0) - s;
        float2 kk = select(float2(1.0), lim / dv, abs(dv) > 1e-6);
        tail = s + dv * saturate(min(kk.x, kk.y));
        float d;
        if (shape < 0.5) {
            d = sqrt(gn_seg2(q, s, tail)) - rad;
        } else {                                              // sparkle: thin cross
            float2 v = abs(q - s);
            float a = min(v.x, v.y) + max(v.x, v.y) * 0.08;
            d = min(a - rad * 0.12, length(q - s) - rad * 0.5);
            d = min(d, sqrt(gn_seg2(q, s, tail)) - rad * 0.25);
        }
        float scr = d / (depth * cells);                       // to in.p units
        float fade = smoothstep(0.0, 0.3, z) * (1.0 - smoothstep(0.85, 1.0, z));
        float tw = 1.0 - twinkle * (0.5 + 0.5 * sin(TAU * (g.beat * 2.0 + h.x * 7.0)));
        float m = gn_fill(scr, px, 0.0) * fade * tw * (0.35 + 0.65 * z);
        if (m > best) { best = m; hue = h.y; }
    }
    return gen_out(best, rainbow * hue, g, c);
}

// ---------- lissajous: a beat-synced Lissajous figure (≤ 64 segments) ----------

fragment float4 gen_lissajous(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                              constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float fa = p[0], fb = p[1], pspeed = p[2], size = p[3], stretch = p[4], thick = p[5];
    int segs = int(clamp(p[6], 8.0, 64.0));
    float spin = p[7], style = p[8], dotR = p[9], soft = p[10], pulse = p[11], jump = p[12], rainbow = p[13];
    float px = gn_px(g);
    float sz = size * (1.0 + pulse * g.pulse * 0.3);
    float2 scale = float2(sz * stretch, sz);
    float2 q = rot2(TAU * spin * g.beat) * in.p;
    float margin = thick + dotR + soft * 0.1 + 4.0 * px;
    if (any(abs(q) > scale + margin)) return gen_out(0.0, 0.0, g, c);
    float ph = TAU * (pspeed * g.beat + jump * hash11(g.trigger * 0.618 + 0.7));
    float dl = 1e9, dl2 = 1e9, dd = 1e9, tl = 0.0, tl2 = 0.0;
    float st = TAU / float(segs);
    float2 a = float2(sin(ph), 0.0) * scale;
    for (int k = 1; k <= segs; k++) {
        float t = float(k) * st;
        float2 b = float2(sin(fa * t + ph), sin(fb * t)) * scale;
        float2 pa = q - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
        float2 e = pa - ba * h;
        float d2 = dot(e, e);
        float tt = t - st * (1.0 - h);
        if (d2 < dl) {
            if (abs(tt - tl) > 2.5 * st) { dl2 = dl; tl2 = tl; }   // keep the best other branch too
            dl = d2; tl = tt;
        } else if (d2 < dl2 && abs(tt - tl) > 2.5 * st) { dl2 = d2; tl2 = tt; }
        dd = min(dd, dot(q - b, q - b));
        a = b;
    }
    // refine on the true curve (Newton on |C(t) - q|²) from the two best branches:
    // smooth instead of a polyline
    float2 T = float2(tl, tl2);
    for (int i = 0; i < 5; i++) {
        float2 sa = sin(fa * T + ph), ca = cos(fa * T + ph), sb = sin(fb * T), cb = cos(fb * T);
        float2 cx = sa * scale.x - q.x, cy = sb * scale.y - q.y;
        float2 c1x = fa * ca * scale.x, c1y = fb * cb * scale.y;
        float2 d1 = cx * c1x + cy * c1y;
        float2 d2 = c1x * c1x + c1y * c1y - cx * fa * fa * sa * scale.x - cy * fb * fb * sb * scale.y;
        T -= clamp(d1 / max(abs(d2), 1e-6), -0.75 * st, 0.75 * st);
    }
    float2 ex = sin(fa * T + ph) * scale.x - q.x, ey = sin(fb * T) * scale.y - q.y;
    float2 e2 = ex * ex + ey * ey;
    if (dl2 > 1e8) e2.y = 1e9;
    dl = min(e2.x, e2.y);
    tl = e2.x <= e2.y ? T.x : T.y;
    float kl = fract(tl / TAU) * float(segs);
    float m = 0.0;
    if (style < 0.5 || style > 1.5) m = gn_fill(sqrt(dl) - thick, px, soft * 0.1);
    if (style > 0.5) m = max(m, gn_fill(sqrt(dd) - dotR, px, soft * 0.1));
    return gen_out(m, rainbow * kl / float(segs), g, c);
}

// ---------- plasma: flowing value-noise field, smooth / banded / contours / posterized ----------

inline float gn_fbm(float2 p, int oct) {
    float v = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        v += a * vnoise(p);
        n += a;
        p = rot2(0.7) * p * 2.03 + float2(17.1, 9.3);
        a *= 0.5;
    }
    return v / n;
}

fragment float4 gen_plasma(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                           constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float scale = p[0], evolve = p[1];
    int oct = int(clamp(p[2], 1.0, 5.0));
    float warp = p[3], fangle = p[4] * PI / 180.0, fspeed = p[5], style = p[6], levels = max(p[7], 1.0);
    float lw = p[8], contrast = p[9], pwarp = p[10], jump = p[11], rainbow = p[12];
    float px = gn_px(g);
    float2 q = in.p * scale - float2(cos(fangle), sin(fangle)) * fspeed * g.beat;
    q += hash22(float2(floor(g.trigger) * jump, 3.7)) * 50.0 * step(0.001, jump);
    float tb = g.beat * evolve;
    float w = warp + pwarp * g.pulse;
    if (w > 0.0) {
        float2 o = float2(vnoise(q * 0.7 + float2(tb, 1.3)), vnoise(q * 0.7 + float2(5.2, -tb)));
        q += (o - 0.5) * 2.0 * w;
    }
    float v = gn_fbm(q + float2(tb * 0.5, -tb * 0.3), oct);
    float vr = (v - 0.5) * contrast + 0.5;                   // unclipped, for contour lines
    v = saturate(vr);
    float m;
    if (style < 0.5) {                                        // smooth
        m = v;
    } else if (style < 1.5) {                                 // bands
        float x = v * levels;
        m = gn_band(x, 0.5, fwidth(x), 0.0);
    } else if (style < 2.5) {                                 // contour lines, constant width on screen
        float x = vr * levels;
        float fw = max(fwidth(x), 1e-5);
        float d = abs(fract(x + 0.5) - 0.5) / fw * px;        // distance to the nearest line, in.p units
        m = gn_fill(d - lw, px, 0.0) * (1.0 - smoothstep(0.3, 0.6, fw));
    } else {                                                  // posterized steps
        float x = v * levels;
        float e = fwidth(x) * 0.75 + 1e-4;
        float s = floor(x - 0.5) + smoothstep(0.5 - e, 0.5 + e, fract(x - 0.5));
        m = saturate(s / max(levels - 1.0, 1.0));
        return gen_out(m, rainbow * m, g, c);              // flat hue per step
    }
    return gen_out(m, rainbow * v, g, c);
}
