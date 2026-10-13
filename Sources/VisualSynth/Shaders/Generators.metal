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
