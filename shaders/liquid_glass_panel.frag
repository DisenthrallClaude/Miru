// Liquid Glass — rounded-rect glass panel as a REAL backdrop filter
// (Impeller path). v1.6.4; v1.6.6 dual-pass frosted architecture.
//
// v1.6.6: the Dart side now stacks TWO BackdropFilters (liquid_glass_easy
// architecture): pass 1 = engine ImageFilter.blur(frostSigma) which blurs
// ALL channels of the backdrop; pass 2 = THIS shader, whose `image` sampler
// receives the ALREADY-BLURRED backdrop. Background is frosted BEFORE it
// is refracted. The in-shader 13-tap kernel below is therefore a secondary
// tuning knob (blur uniform, default 0 = off) — the primary frost comes
// from the engine pass.
//
// Brings the same physics as the welcome-screen orb lens to app chrome
// (floating dock, nav bar): real refraction of the content scrolling
// under the glass, a bevelled rim that bends harder, chromatic dispersion
// at the rim, a top inner specular highlight, and a grounding bottom
// shadow line.
//
// The filter is applied inside a ClipRRect(BackdropFilter) whose bounds
// ARE the panel, so:
//   * first uniform vec2 (sceneRes, engine-set) = panel size in physical px
//   * FlutterFragCoord().xy = panel-local physical px, origin at the
//     panel's top-left corner
//   * first sampler2D = engine-bound backdrop snapshot
#include <flutter/runtime_effect.glsl>

uniform vec2 sceneRes;    // engine-set: panel physical size
uniform float radius;     // corner radius, physical px
uniform float thickness;  // how thick the glass is (refraction amount 0..1)
uniform float dispersion; // chromatic dispersion at the rim (0..0.03)
uniform float highlight;  // top inner specular strength (0..1)
uniform vec3 tintColor;   // glass body tint (rgb)
uniform float tintAmt;    // how much body tint to mix in (0..1)
uniform float blur;       // gaussian sigma in PHYSICAL px; 0 disables

uniform sampler2D image;  // engine-bound: the backdrop to refract

out vec4 fragColor;

// Rounded-rect SDF (negative inside).
float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec2 toUV(vec2 pos) {
  vec2 uv = pos / sceneRes;
  // Impeller's GLES backend has a bottom-up texture row order.
  #ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
  #endif
  return uv;
}

// v1.6.5: optional in-shader gaussian blur of the backdrop, sampled at
// `pos` (v1.6.6: SECONDARY — the engine-level ImageFilter.blur pass on
// the Dart side already frosts ALL channels; this kernel only runs when
// the blur uniform is > 0, for extra rim-zone softening if ever needed).
//
// 13-tap dual-ring poisson kernel: centre + 6 taps at sigma + 6 taps
// at 2*sigma (rotated 30 degrees). Weights come from the unit gaussian
// (e^-0.5 = 0.6065, e^-2 = 0.1353), normalised to sum to 1.
//
// Cost: 13 texture fetches, only on the dock's small region.
vec4 blurSample(vec2 pos) {
  if (blur < 0.5) {
    return texture(image, toUV(pos));
  }
  const float WC = 0.1835; // centre
  const float W1 = 0.1113; // ring 1 (at sigma)
  const float W2 = 0.0248; // ring 2 (at 2 sigma)
  vec4 sum = texture(image, toUV(pos)) * WC;
  for (int i = 0; i < 6; i++) {
    float a = 1.0471976 * float(i) + 0.2617994; // 60 deg steps, 15 deg off
    vec2 dir = vec2(cos(a), sin(a));
    // ring 1 at +sigma, ring 2 at -2*sigma (opposite side, 2x radius):
    // 6 directions x 2 radii = 12 outer taps in 12 distinct positions,
    // the kernel stays radially symmetric (each direction has a tap at
    // each radius on both sides through the centre line).
    sum += texture(image, toUV(pos + dir * blur)) * W1;
    sum += texture(image, toUV(pos - dir * blur * 2.0)) * W2;
  }
  return sum;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 half2 = sceneRes * 0.5;
  // Panel-local centered coordinates.
  vec2 c = p - half2;
  float d = sdRoundedBox(c, half2, radius);

  if (d >= 0.0) {
    // Outside the panel shape (corner regions beyond the rounding):
    // pass the backdrop through; ClipRRect discards it anyway.
    fragColor = texture(image, toUV(p));
    return;
  }

  float edgeDist = -d; // px from the rim, growing inward
  float bevelW = max(min(radius, min(half2.x, half2.y) * 0.5), 1.0);
  // 1.0 exactly at the rim, 0.0 past the bevel band.
  float bev = 1.0 - smoothstep(0.0, bevelW, edgeDist);

  // A thick plate: the interior magnifies gently, the bevel at the rim
  // pulls hard — content crossing the rim stretches along the edge.
  float k = thickness * (0.34 + 0.62 * bev * bev);
  // Refraction: sample outward from the panel centre so content appears
  // pulled toward the middle (convex plate reading).
  vec2 n = c / max(half2, vec2(1.0));      // -1..1, corners exceed slightly
  vec2 back = n * k * bevelW * 1.6;

  // Chromatic dispersion: R/G/B land slightly apart — strongest at rim.
  // The green (base) channel goes through the gaussian kernel; R/B take
  // cheap single taps at their tiny dispersion offsets (1-2 px at the rim)
  // where the blur difference is imperceptible — 15 fetches total.
  float disp = dispersion * (0.25 + 0.75 * bev);
  vec4 cr = texture(image, toUV(p - back * (1.0 + disp)));
  vec4 cg = blurSample(p - back);
  vec4 cb = texture(image, toUV(p - back * (1.0 - disp)));
  vec4 refracted = vec4(cr.r, cg.g, cb.b, max(cg.a, max(cr.a, cb.a)));

  // Glass body: milky tint mixed in, stronger near the rim (the plate is
  // thickest there and catches the light). v1.6.6: interior floor raised
  // 0.55 → 0.68 — with the engine-pass frost the interior colour washes
  // stay soft, and a slightly sturdier milk base keeps tab labels readable
  // over bright covers (snow scenes) in light theme.
  float body = tintAmt * (0.68 + 0.32 * bev);
  vec3 glass = mix(refracted.rgb, tintColor, clamp(body, 0.0, 1.0));
  float alpha = mix(refracted.a, 1.0, clamp(body * 0.9, 0.0, 0.95));

  // Top inner specular: a soft band along the top rim — light catching
  // the far edge of the glass. p.y IS the distance to the top rim.
  float topBand = 1.0 - smoothstep(0.0, bevelW * 2.8, p.y);
  // Fade the band out near the left/right rims so corners stay clean.
  float xFade = smoothstep(0.0, radius * 1.6, half2.x - abs(c.x));
  float spec = topBand * xFade * highlight;
  glass += vec3(spec);

  // Bottom inner shadow: grounding contact line along the bottom rim.
  float bottomBand = 1.0 - smoothstep(0.0, bevelW * 2.0, sceneRes.y - p.y);
  glass -= vec3(bottomBand * 0.05);

  fragColor = vec4(clamp(glass, 0.0, 1.0), alpha);
}
