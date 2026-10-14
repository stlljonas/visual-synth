// Image layers (Camera, Image / Video): a picture from outside, placed, keyed and coloured.
// Like a generator, plus the picture as texture(0). Params: ImageLayers.params in Generators.swift.

inline float4 img_sample(texture2d<float> tex, float2 uv, int outside) {
    if (outside == 1) return tex.sample(linearRepeat, uv);
    if (outside == 2) return tex.sample(linearMirror, uv);
    return tex.sample(linearClamp, uv);
}

fragment float4 gen_image(VOut in [[stage_in]], constant Globals& g [[buffer(0)]],
                          constant float* p [[buffer(1)]], constant GenCommon& c [[buffer(2)]],
                          texture2d<float> tex [[texture(0)]]) {
    int fit = int(p[0]), mirror = int(p[1]);
    float zoom = p[2] * (1.0 + p[13] * g.pulse * 0.5);
    float2 pan = float2(p[3] * g.aspect, p[4]);
    float angle = p[5] * PI / 180.0 + TAU * g.beat * p[6];
    int outside = int(p[7]), colour = int(p[8]);
    float contrast = p[9];
    int key = int(p[10]);
    float thresh = p[11], ksoft = p[12];

    // screen → picture: half-size of the picture in in.p units, before zoom
    float ia = float(tex.get_width()) / max(float(tex.get_height()), 1.0);
    float2 half_;
    if (fit == 2) half_ = float2(g.aspect, 1.0);
    else {
        float hy = fit == 0 ? max(1.0, g.aspect / ia) : min(1.0, g.aspect / ia);
        half_ = float2(hy * ia, hy);
    }
    float2 q = rot2(-angle) * (in.p - pan) / zoom;
    float2 uv = float2(q.x / half_.x, -q.y / half_.y) * 0.5 + 0.5;
    if (mirror & 1) uv.x = 1.0 - uv.x;
    if (mirror & 2) uv.y = 1.0 - uv.y;

    // coverage: 1 inside the picture (antialiased edge), everywhere when it tiles
    float cover = 1.0;
    if (outside == 0) {
        float2 d = abs(q) - half_;
        cover = aa_fill(max(d.x, d.y), 0.0);
        if (cover <= 0.0) return float4(0.0);
    }

    float3 rgb = img_sample(tex, uv, outside).rgb;
    rgb = saturate((rgb - 0.5) * contrast + 0.5);
    float y = luma(rgb);

    float mask;
    if (key == 1) mask = smoothstep(thresh - ksoft, thresh + ksoft + 1e-4, y);
    else if (key == 2) mask = 1.0 - smoothstep(thresh - ksoft, thresh + ksoft + 1e-4, y);
    else if (key == 3) {
        // Sobel on brightness, one screen pixel apart (in picture space)
        float2 px = float2(length(float2(dfdx(uv.x), dfdy(uv.x))), length(float2(dfdx(uv.y), dfdy(uv.y))));
        px = max(px, float2(0.5 / float(tex.get_width()), 0.5 / float(tex.get_height())));
        float l[9];
        for (int j = 0; j < 3; j++)
            for (int i = 0; i < 3; i++)
                l[j * 3 + i] = luma(saturate((img_sample(tex, uv + float2(i - 1, j - 1) * px, outside).rgb - 0.5) * contrast + 0.5));
        float gx = (l[2] + 2.0 * l[5] + l[8]) - (l[0] + 2.0 * l[3] + l[6]);
        float gy = (l[6] + 2.0 * l[7] + l[8]) - (l[0] + 2.0 * l[1] + l[2]);
        float e = length(float2(gx, gy));
        mask = smoothstep(thresh * 0.5 - ksoft, thresh * 0.5 + ksoft + 1e-4, e);
        y = 1.0;   // outlines are drawn in full colour, not the picture's brightness
    } else mask = 1.0;
    mask *= cover;

    float k = c.bright * mix(1.0, g.pulse, c.gate);
    float3 tint = g.palOn > 0.5 ? palette_at(g, c.hue + g.palShift) : hsv2rgb(float3(c.hue, c.sat, 1.0));
    float3 col;
    if (colour == 0) {
        // Saturation 0.75 (default) = as filmed; higher boosts, lower fades to grey. Outlines take the layer's hue.
        col = key == 3 ? tint : mix(float3(y), rgb, c.sat / 0.75);
    } else if (colour == 1) {
        col = float3(y);
    } else if (colour == 2) {
        col = tint * y;
    } else {
        col = palette_at(g, c.hue + g.palShift + y * max(g.palSpread, 0.25)) * smoothstep(0.0, 0.15, y);
    }
    col = max(col, 0.0) * k;
    if (c.blend > 2.5) return float4(mix(float3(1.0), col, mask), 1.0);   // Multiply
    return float4(col * mask, mask);
}
