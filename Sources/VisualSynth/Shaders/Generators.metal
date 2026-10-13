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
