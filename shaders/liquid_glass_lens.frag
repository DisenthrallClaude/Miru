// Liquid Glass — the lens (backdrop refraction) effect.
//
// Ported 1:1 from Appllama/liquid-glass-screens src/liquid-glass/glass.ts
// (LENS_SKSL, GPL-3.0). The original runs as a Skia backdrop filter that
// bends whatever is drawn under it; Flutter has no arbitrary-shader backdrop
// filters, so the scene is pre-captured into a ui.Image of the exact physical
// screen size and passed as `image`. Used for the Astro (night) theme whose
// backdrop is a static starfield — the capture is done once, so the lens is
// a pixel-faithful port (magnification, bevel shear, RGB dispersion, slosh).
//
// The Sky (day) theme has a live video backdrop which cannot be sampled into
// a shader; its lens is approximated with scaled clip layers in widget space
// (see liquid_glass_welcome.dart).
#include <flutter/runtime_effect.glsl>

uniform sampler2D image;  // the captured scene, screen-physical-pixel sized
uniform vec2 sceneRes;    // physical px size of `image`
uniform vec2 c;           // sphere centre, physical px
uniform float r;          // sphere radius, physical px
uniform float amount;     // how thick the glass is
uniform float bezel;      // how much of the radius is the bevelled edge
uniform float disp;       // dispersion: how far apart the three channels land
uniform vec2 slosh;       // px: how far the picture inside is dragged

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 d = (p - c) / r;
  float rr = length(d);
  if (rr >= 1.0) {
    // Outside the lens the scene shows through unchanged.
    fragColor = texture(image, p / sceneRes);
    return;
  }
  // A thick lens: the whole interior magnifies, and the bevel at the rim
  // pulls hard — content crossing it stretches along the edge.
  float bev = smoothstep(1.0 - bezel, 1.0, rr);
  float k = amount * (0.42 + 0.58 * bev * bev);
  // The liquid inside lags the glass: the picture is dragged along with the
  // motion, most at the centre and not at all at the rim, and settles back.
  vec2 back = (p - c) * k + slosh * (1.0 - rr * rr);
  vec4 cr = texture(image, (p - back * (1.0 + disp)) / sceneRes);
  vec4 cg = texture(image, (p - back) / sceneRes);
  vec4 cb = texture(image, (p - back * (1.0 - disp)) / sceneRes);
  float aa = max(cg.a, max(cr.a, cb.a));
  fragColor = vec4(cr.r, cg.g, cb.b, aa);
}
