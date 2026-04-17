/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/c2_dof
  Depth of field - gather pass.

  Separates the scene into near (in front of focus) and far (behind focus)
  blurred layers, each stored in their own buffer for compositing in c2b.

  Outputs:
    colortex1  (RGBA16 UNORM): far-blurred color (Reinhard-encoded) + far alpha
    colortex13 (RGBA16F):      near-blurred color (HDR) + near alpha

  Near alpha is derived from two sources:
    1. Center pixel's own near CoC (pixel is itself in front of focus)
    2. Fraction of gathered samples that are near-field (bleeding detection)
  This ensures foreground objects correctly bleed over in-focus backgrounds.

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(location = 0) out vec4 far_layer;   // colortex1
layout(location = 1) out vec4 near_layer;  // colortex13

/* RENDERTARGETS: 1,13 */

in vec2 uv;

// ------------
//   Uniforms
// ------------

uniform sampler2D noisetex;
uniform sampler2D colortex0;
uniform sampler2D depthtex0;

uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform float near, far;

uniform float aspectRatio;
uniform float centerDepthSmooth;

uniform int frameCounter;

uniform vec2 view_pixel_size;

#include "/include/misc/lod_mod_support.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/sampling.glsl"
#include "/include/utility/space_conversion.glsl"

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec3 original = texelFetch(colortex0, texel, 0).rgb;

    float depth = texelFetch(depthtex0, texel, 0).x;

#ifdef LOD_MOD_ACTIVE
    float depth_lod = texelFetch(lod_depth_tex, texel, 0).x;

    if (is_lod_terrain(depth, depth_lod)) {
        depth = view_to_screen_space_depth(
            gbufferProjection,
            screen_to_view_space_depth(lod_projection_matrix_inverse, depth_lod)
        );
    }
#endif

    // Skip DoF for hand-held items
    if (depth < hand_depth) {
        far_layer  = vec4(original / (original + 1.0), 0.0);
        near_layer = vec4(0.0);
        return;
    }

    // ----- Focus plane -----

    float focus_screen = DOF_FOCUS < 0.0
        ? centerDepthSmooth
        : view_to_screen_space_depth(gbufferProjection, DOF_FOCUS);

    float focus_view = screen_to_view_space_depth(gbufferProjectionInverse, focus_screen);
    float pixel_view = screen_to_view_space_depth(gbufferProjectionInverse, depth);

    // ----- Signed Circle of Confusion -----
    // Positive  = behind focus  (far field)
    // Negative  = in front of focus (near field)
    // Units: UV-space radius (same scaling as the existing single-pass formula)
    float coc_scale  = DOF_INTENSITY * 0.00002 / 1.37 * gbufferProjection[1][1];
    float signed_coc = (pixel_view - focus_view) * coc_scale;

    float far_max_coc_uv  = float(DOF_MAX_COC)      * view_pixel_size.x;
    float near_max_coc_uv = float(DOF_NEAR_MAX_COC) * view_pixel_size.x;

    // ----- Focus zone -----
    // DOF_FOCUS_ZONE and DOF_MAX_COC are independent controls:
    //   - focus zone creates a dead-band (objects this close to focus stay sharp)
    //   - max CoC limits blur strength after the dead-band
    // Order: subtract zone first, then clamp to max CoC. This way a large focus
    // zone never prevents max CoC blur from being reached.
    float focus_zone_uv  = float(DOF_FOCUS_ZONE) * view_pixel_size.x;
    float biased_abs_raw = max(0.0, abs(signed_coc) - focus_zone_uv);
    float max_coc_side   = signed_coc >= 0.0 ? far_max_coc_uv : near_max_coc_uv;
    float biased_abs     = min(biased_abs_raw, max_coc_side);
    float biased_coc     = sign(signed_coc) * biased_abs;

    // ----- Transition ramps & kernel radius -----
    // DOF_FOCUS_TRANSITION / DOF_NEAR_FOCUS_TRANSITION control how quickly blur SIZE
    // grows from the zone boundary.  Alpha is binary past the zone — the ramp is on
    // the kernel, not the blend strength.
    float far_ramp  = float(DOF_FOCUS_TRANSITION)      * view_pixel_size.x;
    float near_ramp = float(DOF_NEAR_FOCUS_TRANSITION) * view_pixel_size.x;

    float side_ramp  = signed_coc >= 0.0 ? far_ramp : near_ramp;
    float ramp_t     = clamp(biased_abs / max(side_ramp, 1e-6), 0.0, 1.0);
    float ramped_abs = biased_abs * ramp_t;  // grows from 0 at zone boundary, full size after ramp

    // Minimum kernel ensures in-focus pixels still sample neighbors for
    // near-field bleeding detection (~3px footprint)
    float min_kernel = 3.0 * view_pixel_size.x;
    // float kernel     = max(ramped_abs, min_kernel);
    float kernel     = ramped_abs;
    vec2  kernel_uv  = vec2(kernel, kernel * aspectRatio);

    // ----- Temporal Vogel disc rotation -----
    float theta = texelFetch(noisetex, texel & 511, 0).b;
    theta = r1(frameCounter, theta);
    theta *= tau;

    // ----- Gather loop -----
    vec3  far_accum    = vec3(0.0);
    float far_w        = 0.0;
    vec3  near_accum   = vec3(0.0);
    float near_w       = 0.0;
    float near_coverage = 0.0;

    vec2 uv_max = vec2(1.0) - 2.0 * view_pixel_size * rcp(taau_render_scale);

    for (int i = 0; i < DOF_SAMPLES; ++i) {
        vec2 disc   = vogel_disc_sample(i, DOF_SAMPLES, theta);
        vec2 offset = disc * kernel_uv;

        vec2 sample_uv    = clamp(uv + offset, vec2(0.0), uv_max);
        vec2 sample_uv_ts = sample_uv * taau_render_scale;

        vec3  sample_color = textureLod(colortex0,  sample_uv_ts, 0).rgb;
        float sample_depth = textureLod(depthtex0,  sample_uv_ts, 0).x;

        float sample_view = screen_to_view_space_depth(gbufferProjectionInverse, sample_depth);
        float sample_coc  = (sample_view - focus_view) * coc_scale;

        // Same zone-first, then max-CoC-clamp as the center pixel
        float s_biased_raw = max(0.0, abs(sample_coc) - focus_zone_uv);
        float s_max_coc    = sample_coc >= 0.0 ? far_max_coc_uv : near_max_coc_uv;
        float s_biased     = sign(sample_coc) * min(s_biased_raw, s_max_coc);

        // Far contribution (sample is behind focus)
        float w_far = max(0.0, s_biased);
        far_accum += sample_color * w_far;
        far_w     += w_far;

        // Near contribution (sample is in front of focus)
        float w_near = max(0.0, -s_biased);
        near_accum += sample_color * w_near;
        near_w     += w_near;

        // Accumulate near coverage weighted by depth into near-field, normalized
        // by near_ramp — so DOF_NEAR_FOCUS_TRANSITION controls how quickly coverage
        // builds up as well as the center-pixel ramp.
        near_coverage += clamp(w_near / near_ramp, 0.0, 1.0);
    }

    // ----- Normalize -----

    vec3 far_blurred  = (far_w  > 1e-4) ? (far_accum  / far_w)  : original;
    vec3 near_blurred = (near_w > 1e-4) ? (near_accum / near_w) : original;

    // ----- Alpha computation -----

    // Alpha is binary past the focus zone — blur SIZE (kernel) does the transition, not blend strength.
    // Far: 1.0 once any far-field CoC exists
    float far_alpha = biased_coc > 0.0 ? 1.0 : 0.0;

    // Near: take the larger of coverage fraction (bleeding) and own near CoC (binary).
    // near_coverage is already weighted by near_ramp in the loop, so the bleeding
    // transition is still governed by DOF_NEAR_FOCUS_TRANSITION.
    float near_cov_frac = near_coverage / float(DOF_SAMPLES);
    float center_near   = biased_coc < 0.0 ? 1.0 : 0.0;
    float near_alpha    = clamp(max(near_cov_frac, center_near), 0.0, 1.0);

    // ----- Write outputs -----

#ifdef DOF_FAR_BLUR
    // Reinhard-encode HDR far color to fit in RGBA16 UNORM [0,1]
    far_layer = vec4(far_blurred / (far_blurred + 1.0), far_alpha);
#else
    far_layer = vec4(original / (original + 1.0), 0.0);
#endif

#ifdef DOF_NEAR_BLUR
    near_layer = vec4(near_blurred, near_alpha);
#else
    near_layer = vec4(0.0);
#endif
}

#ifndef DOF
#error "This program should be disabled if Depth of Field is disabled"
#endif
