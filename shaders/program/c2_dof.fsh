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

    // Clamp near and far sides to their respective maximum bokeh radii.
    // This must happen before biased_abs so the kernel radius is also capped.
    float far_max_coc_uv  = float(DOF_MAX_COC)      * view_pixel_size.x;
    float near_max_coc_uv = float(DOF_NEAR_MAX_COC) * view_pixel_size.x;
    signed_coc = clamp(signed_coc, -near_max_coc_uv, far_max_coc_uv);

    // ----- Focus zone -----
    // Subtract the sharp-zone radius so objects within DOF_FOCUS_ZONE pixels of
    // CoC stay fully sharp.  The biased CoC drives kernel radius, alpha, and
    // sample weights — raw signed_coc is not used further after this point.
    float focus_zone_uv = float(DOF_FOCUS_ZONE) * view_pixel_size.x;
    float biased_abs    = max(0.0, abs(signed_coc) - focus_zone_uv);
    float biased_coc    = sign(signed_coc) * biased_abs;

    // ----- Kernel radius -----
    // Minimum kernel ensures in-focus pixels still sample neighbors for
    // near-field bleeding detection (~3px footprint)
    float min_kernel = 3.0 * view_pixel_size.x;
    float kernel     = max(biased_abs, min_kernel);
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

    // Near-field threshold: sample CoC must be negative by at least this much
    // to count as a near-field pixel for coverage/bleeding purposes
    float near_threshold = -0.5 * min_kernel;

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
        sample_coc = clamp(sample_coc, -near_max_coc_uv, far_max_coc_uv);

        // Apply focus zone to sample CoC so in-zone samples don't contribute
        // to far/near accumulators
        float s_biased = sign(sample_coc) * max(0.0, abs(sample_coc) - focus_zone_uv);

        // Far contribution (sample is behind focus)
        float w_far = max(0.0, s_biased);
        far_accum += sample_color * w_far;
        far_w     += w_far;

        // Near contribution (sample is in front of focus)
        float w_near = max(0.0, -s_biased);
        near_accum += sample_color * w_near;
        near_w     += w_near;

        // Count samples that are meaningfully near-field for bleed alpha
        if (s_biased < near_threshold) {
            near_coverage += 1.0;
        }
    }

    // ----- Normalize -----

    vec3 far_blurred  = (far_w  > 1e-4) ? (far_accum  / far_w)  : original;
    vec3 near_blurred = (near_w > 1e-4) ? (near_accum / near_w) : original;

    // ----- Alpha computation -----

    // Far alpha: ramp from 0 at zone boundary to 1 over DOF_FOCUS_TRANSITION pixels of CoC
    float far_ramp  = float(DOF_FOCUS_TRANSITION) * view_pixel_size.x;
    float far_alpha = clamp(max(0.0, biased_coc) / far_ramp, 0.0, 1.0);

    // Near alpha: take the larger of:
    //   - Fraction of samples that were near-field (bleeding from neighbors)
    //   - Center pixel's own near CoC, ramped over DOF_NEAR_FOCUS_TRANSITION pixels
    float near_ramp      = float(DOF_NEAR_FOCUS_TRANSITION) * view_pixel_size.x;
    float near_cov_frac  = near_coverage / float(DOF_SAMPLES);
    float center_near    = clamp(max(0.0, -biased_coc) / near_ramp, 0.0, 1.0);
    float near_alpha     = clamp(max(near_cov_frac, center_near), 0.0, 1.0);

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
