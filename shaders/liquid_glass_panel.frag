// Liquid Glass — rounded-rect glass panel as a REAL backdrop filter
// (Impeller path). v1.6.4; v1.6.6 dual-pass; v1.6.7 self-contained RGB frost.
//
// v1.6.7: the dual-BackpropFilter chain (engine blur pass + this shader)
// is REPLACED by a single BackdropFilter(ImageFilter.shader) — the
// v1.6.4/v1.6.5-proven structure that reliably receives the backdrop on
// real devices. Full-channel frost now happens INSIDE this shader:
// R/G/B all go through the 13-tap gaussian kernel (at their dispersion
// offsets), plus a per-pixel grain jitter that breaks up gaussian banding
// and gives the sandblasted "frosted" texture. No dependency on engine-
// level filter chaining semantics (which produced a sharp un-frosted
// strip along the top edge of the dock on real devices).
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

// v1.6.7: cheap 2D hash for the frost grain (dithered blur).
vec2 hash2(vec2 px) {
  vec3 p3 = fract(vec3(px.xyx) * vec3(0.1031, 0.1030, 0.0973));
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.xx + p3.yz) * p3.zy);
}

// v1.6.7: full-channel gaussian blur of the backdrop, sampled at `pos`.
// 13-tap dual-ring poisson kernel: centre + 6 taps at sigma + 6 taps
// at 2*sigma (rotated 30 degrees). Weights come from the unit gaussian
// (e^-0.5 = 0.6065, e^-2 = 0.1353), normalised to sum to 1.
//
// Cost: 13 texture fetches per call; R/G/B each call it at their own
// dispersion offset (39 fetches total) — only on the dock's small region.
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
  vec2 halfSize = sceneRes * 0.5;
  // Panel-local centered coordinates.
  vec2 c = p - halfSize;
  float d = sdRoundedBox(c, halfSize, radius);

  if (d >= 0.0) {
    // Outside the panel shape (corner regions beyond the rounding):
    // pass the backdrop through; ClipRRect discards it anyway.
    fragColor = texture(image, toUV(p));
    return;
  }

  float edgeDist = -d; // px from the rim, growing inward
  float bevelW = max(min(radius, min(halfSize.x, halfSize.y) * 0.5), 1.0);
  // 1.0 exactly at the rim, 0.0 past the bevel band.
  float bev = 1.0 - smoothstep(0.0, bevelW, edgeDist);

  // A thick plate: the interior magnifies gently, the bevel at the rim
  // pulls hard — content crossing the rim stretches along the edge.
  float k = thickness * (0.34 + 0.62 * bev * bev);
  // Refraction: sample outward from the panel centre so content appears
  // pulled toward the middle (convex plate reading).
  vec2 n = c / max(halfSize, vec2(1.0));      // -1..1, corners exceed slightly
  vec2 back = n * k * bevelW * 1.6;

  // Chromatic dispersion: R/G/B land slightly apart — strongest at rim.
  // v1.6.7: ALL channels go through the gaussian kernel (each at its own
  // dispersion offset) — the v1.6.5 kernel was green-only, leaving R/B
  // sharp: anime cover edges stayed legible through the glass (the
  // "can still see the anime through the frosted glass" complaint).
  // Plus the frost grain: a per-pixel jitter of the whole kernel centre
  // breaks up gaussian banding — the sandblasted texture of real
  // frosted glass (monochrome jitter, same offset for RGB, no chroma
  // noise).
  float disp = dispersion * (0.25 + 0.75 * bev);
  // Frost grain: subtle kernel-centre dither (±0.09*blur) — enough to
  // break gaussian banding into a sandblasted texture, small enough to
  // read as material grain rather than noise.
  vec2 grain = (hash2(p) - vec2(0.5)) * blur * 0.18;
  vec2 base = p - back + grain;
  vec4 cr = blurSample(base - back * disp);
  vec4 cg = blurSample(base);
  vec4 cb = blurSample(base + back * disp);
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
  float xFade = smoothstep(0.0, radius * 1.6, halfSize.x - abs(c.x));
  float spec = topBand * xFade * highlight;
  glass += vec3(spec);

  // Bottom inner shadow: grounding contact line along the bottom rim.
  float bottomBand = 1.0 - smoothstep(0.0, bevelW * 2.0, sceneRes.y - p.y);
  glass -= vec3(bottomBand * 0.05);

  fragColor = vec4(clamp(glass, 0.0, 1.0), alpha);
}
