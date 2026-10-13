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

fragment float4 gen_spin(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                         constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]]) {
    float count = max(p[0], 1.0), speed = p[1], radius = p[2], size = p[3];
    int rings = int(p[4]);
    float spacing = p[5], counter = p[6], twist = p[7], pulseS = p[8], kick = p[9];
    float outline = p[10], rainbow = p[11];
    float r = length(in.p);
    float a = atan2(in.p.y, in.p.x);
    float sector = TAU / count;
    float s = size * (1.0 + pulseS * g.pulse);
    float mask = 0.0, hue = 0.0;
    for (int k = 0; k < rings; k++) {
        float rk = radius - float(k) * spacing;
        if (rk < 0.0) break;
        float dir = (k % 2 == 1) ? mix(1.0, -1.0, counter) : 1.0;
        float rotA = TAU * (g.beat * speed + g.trigger * kick * 0.125) * dir + twist * float(k);
        float local = a - rotA;
        float idx = round(local / sector);
        float da = idx * sector + rotA;
        float d = length(in.p - rk * float2(cos(da), sin(da))) - s;
        float dm = outline > 0.0 ? abs(d + s * outline * 0.5) - s * (1.0 - outline) * 0.5 - 0.004 * outline : d;
        float m = aa_fill(dm, 0.0);
        if (m > mask) {
            mask = m;
            hue = rainbow * fract(idx / count);
        }
    }
    return gen_out(mask, hue, g, c);
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
    m *= smoothstep(hole * 0.8, hole + 2.0 * px, r);
    return gen_out(m, rainbow * fract(floor(x1) / count), g, c);
}
