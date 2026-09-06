// Liquid Glass — the lens as a REAL backdrop filter (Impeller path).
//
// Ported from Appllama/liquid-glass-screens LENS_SKSL (GPL-3.0). The original
// runs as a Skia backdrop filter bending whatever is drawn under it; here the
// same is achieved with Flutter's ImageFilter.shader, which binds the backdrop
// snapshot to the first sampler and its size to the first vec2 (sceneRes).
//
// The filter is applied over a full-screen BackdropFilter region clipped to
// the orb circle, so FlutterFragCoord is screen-physical-pixel space and the
// uniforms match the original 1:1 (c/r/slosh in physical px).
//
// Requirements enforced by the engine (see ui.ImageFilter.shader):
//   * first uniform is a vec2 → sceneRes (engine-set, do not write it)
//   * first sampler2D → image (engine-bound backdrop)
#include <flutter/runtime_effect.glsl>

uniform vec2 sceneRes;   // engine-set: size of the bound backdrop texture
uniform vec2 c;          // sphere centre, physical px
uniform float r;         // sphere radius, physical px
uniform float amount;    // how thick the glass is
uniform float bezel;     // how much of the radius is the bevelled edge
uniform float disp;      // dispersion: how far apart the three channels land
uniform vec2 slosh;      // px: how far the picture inside is dragged

uniform sampler2D image; // engine-bound: the backdrop to refract

out vec4 fragColor;

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
  vec2 d = (p - c) / r;
  float rr = length(d);
  if (rr >= 1.0) {
    // Outside the lens the scene shows through unchanged.
    fragColor = texture(image, toUV(p));
    return;
  }
  // A thick lens: the whole interior magnifies, and the bevel at the rim
  // pulls hard — content crossing it stretches along the edge.
  float bev = smoothstep(1.0 - bezel, 1.0, rr);
  float k = amount * (0.42 + 0.58 * bev * bev);
  // The liquid inside lags the glass: the picture is dragged along with the
  // motion, most at the centre and not at all at the rim, and settles back.
  vec2 back = (p - c) * k + slosh * (1.0 - rr * rr);
  vec4 cr = texture(image, toUV(p - back * (1.0 + disp)));
  vec4 cg = texture(image, toUV(p - back));
  vec4 cb = texture(image, toUV(p - back * (1.0 - disp)));
  float aa = max(cg.a, max(cr.a, cb.a));
  fragColor = vec4(cr.r, cg.g, cb.b, aa);
}
