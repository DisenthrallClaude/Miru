// Liquid Glass — rounded-rect glass panel as a REAL backdrop filter
// (Impeller path). v1.6.4.
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
  float disp = dispersion * (0.25 + 0.75 * bev);
  vec4 cr = texture(image, toUV(p - back * (1.0 + disp)));
  vec4 cg = texture(image, toUV(p - back));
  vec4 cb = texture(image, toUV(p - back * (1.0 - disp)));
  vec4 refracted = vec4(cr.r, cg.g, cb.b, max(cg.a, max(cr.a, cb.a)));

  // Glass body: milky tint mixed in, stronger near the rim (the plate is
  // thickest there and catches the light).
  float body = tintAmt * (0.55 + 0.45 * bev);
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
