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
