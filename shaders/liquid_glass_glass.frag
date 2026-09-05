// Liquid Glass — the glass sphere (dome / button) effect.
//
// Ported 1:1 from Appllama/liquid-glass-screens src/liquid-glass/glass.ts
// (GLASS_SKSL, GPL-3.0) to a Flutter fragment shader. All uniforms are in
// physical pixels because FlutterFragCoord() is physical-pixel space.
//
// It draws (all inside a rect covering the sphere plus halo):
//  - the halo outside the rim (grey shade by day, blue-white glow by night)
//  - the milky body lift inside, the hairline rim light, the upper-left sheen
//  - while the sphere is being pushed: the chromatic caustic — a soft
//    lavender-cyan bloom focusing into a bowl of light with a gold thread
//  - the small button state: an iridescent edge that picks up nearby colour.
#include <flutter/runtime_effect.glsl>

uniform vec2 c;      // sphere centre, physical px
uniform float r;     // sphere radius, physical px
uniform float glow;  // 0..1, how hard the sphere is being thrown around
uniform vec2 dv;     // unit vector toward the leading edge
uniform float small; // 0 = the gate dome, 1 = the + button
uniform float caus;  // 0..1, how much of the caustic this size of sphere shows
uniform float night; // 0 = daylight tuning, 1 = night tuning

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 d = (p - c) / r;
  float rr = length(d);
  if (rr > 1.34) {
    fragColor = vec4(0.0);
    return;
  }
  float aa = 1.4 / r;
  float inside = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, rr);
  vec2 nd = d / max(rr, 1e-4);

  // ── halo outside the rim ─────────────────────────────────────────────────
  float haloW = mix(mix(0.075, 0.20, small), mix(0.16, 0.30, small), night);
  float halo = (1.0 - smoothstep(1.0, 1.0 + haloW, rr)) * (1.0 - inside);
  float shDay = halo * (0.075 + 0.11 * smoothstep(-0.4, 1.0, d.y)) *
      mix(1.0, 1.5, small);
  float shNight = halo * halo * (0.10 + 0.08 * smoothstep(0.6, -1.0, d.y)) *
      mix(1.0, 1.4, small);
  float sh = mix(shDay, shNight, night);

  // ── the body ─────────────────────────────────────────────────────────────
  float dome = 1.0 - smoothstep(0.0, 1.0, rr);
  float aDay = mix(0.06 + 0.06 * dome, 0.22 + 0.08 * dome, small);
  float aNight = mix(0.018 + 0.035 * dome, 0.20 + 0.08 * dome, small);
  float a = mix(aDay, aNight, night);
  vec3 col = mix(vec3(1.0), vec3(0.93, 0.96, 1.0), night);

  // ── rim and sheen ────────────────────────────────────────────────────────
  float rim = smoothstep(0.958, 0.990, rr) * (1.0 - smoothstep(0.990, 1.0, rr));
  float inner = smoothstep(0.90, 0.975, rr) * (1.0 - smoothstep(0.975, 1.0, rr));
  float up = clamp(dot(nd, normalize(vec2(0.30, -0.95))), 0.0, 1.0);
  float sheen = smoothstep(0.86, 0.945, rr) *
          (1.0 - smoothstep(0.965, 0.995, rr)) * pow(up, 1.3) +
      smoothstep(0.62, 0.90, rr) * (1.0 - smoothstep(0.90, 0.97, rr)) *
          pow(up, 2.2) * 0.35;
  float lowRim = smoothstep(0.86, 0.975, rr) * (1.0 - smoothstep(0.975, 1.0, rr)) *
      pow(clamp(dot(nd, normalize(vec2(0.42, 0.90))), 0.0, 1.0), 2.4);
  a += rim * mix(0.62, 0.80, small) + sheen * mix(0.62, 0.50, small) +
      lowRim * mix(0.14, 0.40, small);
  col = mix(col, vec3(0.70, 0.72, 0.76), inner * 0.34);

  // ── motion caustic ───────────────────────────────────────────────────────
  float g = glow * caus;
  if (g > 0.002) {
    a += g * mix(0.12, 0.05, night) * (1.0 - smoothstep(0.80, 1.0, rr));

    vec2 ax = dv;
    vec2 px = vec2(-ax.y, ax.x);
    float u = dot(d, px);
    float v = dot(d, ax);

    // focus: a soft bloom at a nudge, a crisp bowl at a throw
    float focus = smoothstep(0.10, 0.80, g);
    float holeR = mix(0.06, 0.245, focus);
    float soft = mix(0.55, 0.0, focus);

    float eo = length(vec2(u / 0.52, (v - 0.639) / 0.361));
    float eh = length(vec2(u, v - 0.750)) / holeR;

    float band = (1.0 - smoothstep(0.86 - soft, 1.06 + soft * 0.5, eo)) *
        smoothstep(0.80 - soft * 0.6, 1.18 + soft, eh);
    band *= 1.0 - smoothstep(0.955, 1.0, rr);

    vec3 cyan = vec3(0.36, 0.86, 0.96);
    vec3 azur = vec3(0.06, 0.53, 0.98);
    vec3 deep = mix(vec3(0.12, 0.31, 0.91), vec3(0.22, 0.44, 1.0), night);
    vec3 lav = vec3(0.66, 0.68, 0.92);
    vec3 ring = mix(cyan, azur, smoothstep(0.46, 0.72, eo));
    ring = mix(ring, deep, smoothstep(0.72, 0.86, eo));
    ring = mix(lav, ring, 0.35 + 0.65 * focus);

    float grade = 0.28 + 0.72 * smoothstep(0.42, 0.80, eo);
    float ba = band * grade *
        mix(mix(0.55, 0.92, focus), mix(0.30, 0.55, focus), night) * g;
    col = mix(col, ring, clamp(ba * mix(1.25, 1.6, night), 0.0, 1.0));
    a += ba;

    // the light that gets through the hole
    a += (1.0 - smoothstep(0.10, 1.06, eh)) * g * mix(0.30, 0.16, night) *
        focus * (1.0 - smoothstep(0.94, 1.0, rr));

    // dispersion: a hairline of pale gold just outside the blue
    float trail = 0.35 + 0.65 * smoothstep(0.2, 0.9, -v);
    float gold = smoothstep(1.115, 1.145, eo) *
        (1.0 - smoothstep(1.155, 1.19, eo)) *
        (1.0 - smoothstep(0.965, 1.0, rr)) * g * focus * trail;
    col = mix(col, vec3(1.0, 0.85, 0.42), clamp(gold * 1.4, 0.0, 1.0));
    a += gold * 0.32;

    // the cyan trace along the rim, strongest where the ring meets it
    float lobe = 0.45 + 0.55 * (1.0 - smoothstep(0.55, 1.25, eo));
    float trace = rim * lobe * g;
    col = mix(col, vec3(0.30, 0.86, 1.0), clamp(trace * 1.7, 0.0, 1.0));
    a += trace * 0.35;
  }

  // ── the button's iridescent edge ─────────────────────────────────────────
  if (small > 0.01) {
    float ang = atan(d.y, d.x);
    float edge = smoothstep(0.955, 0.985, rr) *
        (1.0 - smoothstep(0.985, 1.0, rr));
    vec3 iris = vec3(
        0.5 + 0.5 * cos(6.2832 * (ang * 0.55 + 0.00)),
        0.5 + 0.5 * cos(6.2832 * (ang * 0.55 + 0.33)),
        0.5 + 0.5 * cos(6.2832 * (ang * 0.55 + 0.67)));
    col = mix(col, iris, clamp(edge * 0.28 * small, 0.0, 1.0));
    float line = smoothstep(0.985, 0.995, rr) *
        (1.0 - smoothstep(0.995, 1.0, rr));
    col = mix(col, vec3(0.55, 0.56, 0.60), clamp(line * 0.55 * small, 0.0, 1.0));
    a += line * 0.30 * small;
  }

  a = clamp(a, 0.0, 1.0) * inside + sh;
  vec3 haloCol = mix(vec3(0.0), vec3(0.55, 0.72, 1.0), night);
  vec3 outc = mix(haloCol, col, inside);
  fragColor = vec4(outc * a, a);
}
