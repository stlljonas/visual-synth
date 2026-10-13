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
