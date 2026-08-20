#version 460 core
#include <flutter/runtime_effect.glsl>

// Burning a message away.
//
// # What went wrong the first time, and what fixes it
//
// The first version added a linear term across the width, which meant the
// front advanced left to right at a constant rate whatever the noise did. It
// read as a wipe with texture on it rather than as something catching fire,
// and the noise on top was high frequency everywhere, so the description it
// earned was "crazy fire from the left".
//
// Fire does not work like that. A burn has a **coherent front**, a smooth
// boundary that wanders slowly, with fine detail only on the boundary itself.
// So the field here is built in two parts:
//
//   * a low frequency shape, two octaves, which decides where the front is;
//   * a high frequency term at a tenth of the amplitude, which frays it.
//
// And it spreads outward from a point rather than across an axis, so the
// message is consumed from somewhere rather than swept.
//
// # The heat
//
// Four bands, narrow: a white core barely wider than a line, orange behind it,
// a band of char, then nothing. The char is what sells it. Without a dark
// band the flame looks like a coloured filter passing over the text.

uniform vec2 uSize;

// 0 is intact, 1 is gone.
uniform float uProgress;

// Moves per message, so no two burn identically.
uniform float uSeed;

// 0 paints the alpha mask that eats the bubble, 1 paints the fire on the tear,
// 2 paints the embers, which are drawn on a larger canvas than the bubble so
// they can leave it.
uniform float uMode;

// Where the bubble sits inside the canvas being painted, in pixels. Only used
// by the ember pass, which is given room above and to the sides.
uniform vec4 uBubble;

out vec4 fragColor;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two octaves. Enough to wander, not enough to be busy.
float shape(vec2 p) {
    return valueNoise(p) * 0.66 + valueNoise(p * 2.07) * 0.34;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;

    // Aspect-corrected, or the front is an ellipse on a wide bubble.
    float aspect = uSize.x / max(uSize.y, 1.0);
    vec2 p = vec2(uv.x * aspect, uv.y);

    // Downward. A message is read from the top, so consuming it from the top
    // takes the words in the order they were read, and the char is left below
    // the flame where it belongs rather than above it.
    float front = uv.y;

    // The front: a smooth boundary that wanders. The noise is scaled low, so
    // this is a shape rather than a texture.
    float wander = (shape(p * 3.1 + uSeed * 7.0) - 0.5) * 0.30;

    // The fraying, at a tenth of the amplitude. This is the only high frequency
    // term and it only ever moves the boundary by a hair.
    float fray = (shape(p * 14.0 + uSeed * 3.0) - 0.5) * 0.05;

    float field = front + wander + fray;

    // Rises a little past 1 so the last of the char has somewhere to finish.
    float threshold = uProgress * 1.30 - 0.14;
    float d = field - threshold;

    // --- embers ---------------------------------------------------------------
    //
    // Sparks thrown off the front, drifting up and out and going dark. Drawn on
    // a canvas larger than the bubble, so they leave it and cross the
    // conversation the way real ones would.
    //
    // Procedural rather than a particle system: twenty four of them, each
    // entirely determined by its index and the seed, so there is no state to
    // keep and nothing to update per frame.
    if (uMode > 1.5) {
        vec2 px = FlutterFragCoord().xy;
        vec3 glow = vec3(0.0);
        float total = 0.0;

        for (int i = 0; i < 24; i++) {
            float fi = float(i);
            float r1 = hash(vec2(fi, uSeed));
            float r2 = hash(vec2(fi + 31.0, uSeed));
            float r3 = hash(vec2(fi + 71.0, uSeed));

            // Each spark leaves when the front reaches its row, so they come
            // off the flame rather than all at once.
            float born = 0.06 + r2 * 0.72;
            float age = (uProgress - born) / max(1.0 - born, 0.001);
            if (age < 0.0 || age > 1.0) continue;

            // Starting point on the bubble, on the row the front is at.
            vec2 start = vec2(
                uBubble.x + r1 * uBubble.z,
                uBubble.y + born * uBubble.w);

            // Up, with sideways drift, decelerating. Distances are in units of
            // the bubble's own height so a small bubble throws small sparks.
            float rise = uBubble.w * (0.5 + r3 * 1.7);
            float drift = uBubble.z * (r1 - 0.5) * 0.7;

            vec2 at = start + vec2(
                drift * age,
                -rise * (age - 0.35 * age * age));

            float dist = distance(px, at);

            // Shrinking and cooling as it goes.
            float size = mix(2.6, 0.8, age);
            float spark = exp(-dist * dist / (size * size));
            float fade = (1.0 - age) * (1.0 - age);

            // Yellow when new, deep red when old, which is what an ember does.
            vec3 tint = mix(vec3(1.0, 0.85, 0.45), vec3(0.85, 0.12, 0.02),
                            smoothstep(0.15, 0.85, age));

            glow += tint * spark * fade;
            total += spark * fade;
        }

        float a = clamp(total, 0.0, 1.0);
        fragColor = vec4(glow * a, a);
        return;
    }

    if (uMode < 0.5) {
        // The mask. Two pixels of softness, no more: a soft edge on a dissolve
        // reads as a blur rather than as a tear.
        float alpha = smoothstep(0.0, 0.012, d);
        fragColor = vec4(alpha, alpha, alpha, alpha);
        return;
    }

    // The heated band, and nothing outside it.
    const float CHAR = 0.075;   // how far the darkening reaches ahead
    if (d > CHAR || d < -0.02) {
        fragColor = vec4(0.0);
        return;
    }

    // 1 at the tear, 0 at the outer edge of the char.
    float heat = 1.0 - clamp(d / CHAR, 0.0, 1.0);

    vec3 charred = vec3(0.06, 0.035, 0.03);
    vec3 ember = vec3(0.72, 0.13, 0.01);
    vec3 flame = vec3(1.00, 0.48, 0.05);
    vec3 core = vec3(1.00, 0.93, 0.72);

    // Narrow bands, weighted towards char. Most of the strip is dark and only
    // the last sliver is bright, which is the proportion a real edge has.
    vec3 colour = charred;
    colour = mix(colour, ember, smoothstep(0.28, 0.62, heat));
    colour = mix(colour, flame, smoothstep(0.68, 0.88, heat));
    colour = mix(colour, core, smoothstep(0.93, 1.00, heat));

    // A gentle unevenness along the front rather than a flicker over the whole
    // band, so it looks like the edge is uneven and not like the colour is
    // vibrating.
    float uneven = 0.90 + 0.20 * shape(p * 9.0 + uSeed * 5.0 + uProgress);
    colour *= uneven;

    // Fade the whole band out at the end, so the last of it darkens rather
    // than disappearing mid flame.
    float life = 1.0 - smoothstep(0.88, 1.0, uProgress);

    // Opaque at the tear, falling away through the char.
    float alpha = smoothstep(-0.02, 0.002, d) * (0.35 + 0.65 * heat) * life;

    fragColor = vec4(colour * alpha, alpha);
}
