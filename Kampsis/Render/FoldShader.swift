/// исходник шейдера компилируется при запуске: сборке проекта не нужен отдельный Metal Toolchain
let foldShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FoldUniforms {
    float progress;
    float bend;
    float blur;
    float dimming;
    float opacity;
    float flatten;
    float aspect;
    float unused;
};

struct Varyings {
    float4 position [[position]];
    float2 uv;
};

// наклон крышки: сила перспективы с учётом «уменьшения движения»
static float tilt(constant FoldUniforms &u) {
    return u.progress * u.bend * (1.0 - u.flatten);
}

// один треугольник на весь экран, из которого вырезается видимая область
vertex Varyings backdropVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    return { float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0), uv };
}

fragment float4 backdropFragment(constant FoldUniforms &u [[buffer(0)]]) {
    return float4(0.0, 0.0, 0.0, u.opacity);
}

constant uint sheetCells = 36;

// сетка экрана: верх сужается в перспективе и слегка провисает к середине
vertex Varyings sheetVertex(uint vid [[vertex_id]], constant FoldUniforms &u [[buffer(0)]]) {
    constexpr uint2 corners[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
    uint cell = vid / 6;
    float2 uv = (float2(cell % sheetCells, cell / sheetCells) + float2(corners[vid % 6])) / float(sheetCells);
    float height = 1.0 - uv.y;
    float t = tilt(u);
    float x = (2.0 * uv.x - 1.0) * (1.0 - 0.28 * t * height);
    float sag = 0.012 * sin(M_PI_F * height) + 0.008 * sin(M_PI_F * uv.x) * pow(height, 8.0);
    float y = height - t * sag;
    return { float4(x, 2.0 * y - 1.0, 0.0, 1.0), uv };
}

// граница инея спускается от верхнего края к петле по мере закрытия
static float frostLine(float progress) {
    return 1.10 - 1.38 * smoothstep(0.0, 0.9, progress);
}

// маска краёв: мягкое затухание к бокам и верху, у петли в десять раз короче
static float2 edgeDistance(float2 uv, float aspect) {
    return float2(min(uv.x, 1.0 - uv.x) * aspect, min(uv.y, 10.0 * (1.0 - uv.y)));
}

static float rimWidth(float progress, float height) {
    return max(0.00001, 0.06 * smoothstep(0.0, 0.55, progress) * (0.4 + 0.6 * height));
}

// сколько света проходит: темнее к закрытию, к верху и к боковым краям
static float lightThrough(float progress, float dimming, float height, float x) {
    float sides = pow(abs(2.0 * x - 1.0), 10.0);
    float absorbed = exp(-progress * progress * (0.8 + 1.7 * dimming) * (0.3 + 5.0 * height));
    float closing = 1.0 - smoothstep(0.62, 1.0, progress);
    return absorbed * (1.0 - 0.85 * progress * sides) * closing * closing;
}

fragment float4 sheetFragment(Varyings in [[stage_in]],
                              texture2d<float> sharp [[texture(0)]],
                              texture2d<float> soft [[texture(1)]],
                              texture2d<float> glass [[texture(2)]],
                              constant FoldUniforms &u [[buffer(0)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float height = 1.0 - in.uv.y;
    float p = u.progress;
    float t = tilt(u);

    float line = frostLine(p);
    float frosted = smoothstep(line - 0.22, line + 0.22, height);
    float band = exp(-pow((height - line) / 0.19, 2.0));

    float2 lookup = float2(0.5 + (in.uv.x - 0.5) * (1.0 + 0.036 * t * height * height),
                           in.uv.y - 0.035 * t * sin(M_PI_F * in.uv.y) + 0.012 * t * band);
    float3 sharpColor = sharp.sample(linearClamp, lookup).rgb;
    float3 softColor = soft.sample(linearClamp, lookup).rgb;
    float3 glassColor = glass.sample(linearClamp, lookup).rgb;

    float2 toEdge = edgeDistance(in.uv, u.aspect);
    float rim = rimWidth(p, height);
    float2 inside = smoothstep(float2(0.0), float2(rim), toEdge);
    float rimFrost = (1.0 - smoothstep(0.0, 2.0 * rim, min(toEdge.x, toEdge.y))) * smoothstep(0.0, 0.2, p);

    float3 color = mix(sharpColor, softColor, 0.75 * height * smoothstep(0.0, 0.35, p));
    color = mix(color, glassColor, frosted);
    color = mix(color, glassColor, rimFrost);
    float haze = 0.28 * frosted * smoothstep(0.0, 0.4, p) * u.blur;
    color = mix(color, 0.94 * glassColor + float3(0.006, 0.007, 0.009), haze);
    color += 0.009 * t * band * float3(0.80, 0.89, 1.0);

    color *= lightThrough(p, u.dimming, height, in.uv.x) * inside.x * inside.y;
    return float4(color * u.opacity, u.opacity);
}
"""
