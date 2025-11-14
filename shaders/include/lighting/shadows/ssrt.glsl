#if !defined INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS
#define INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS

#include "/include/lighting/shadows/common.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/sampling.glsl"
#include "/include/utility/space_conversion.glsl"

float linearize_depth_thing(float d,float zNear,float zFar)
{
    float z_n = 2.0 * d - 1.0;
    return 2.0 * zNear * zFar / (zFar + zNear - z_n * (zFar - zNear));
}

bool raymarch_shadow_old(
    sampler2D depth_sampler,
    mat4 projection_matrix,
    mat4 projection_matrix_inverse,
    vec3 ray_origin_screen,
    vec3 ray_origin_view,
    vec3 ray_dir_view,
    bool has_sss,
    float dither,
    out float sss_depth
) {
    const uint step_count = uint(SHADOW_SSRT_STEPS);
    // const float step_ratio = 2.0; // geometric sample distribution
    const float step_ratio = 1.0; // geometric sample distribution
    const float z_tolerance = 10.0; // assumed thickness in blocks

    vec3 ray_dir_screen = normalize(
        view_to_screen_space(
            projection_matrix,
            ray_origin_view + ray_dir_view,
            true
        ) -
        ray_origin_screen
    );

    float ray_length = min_of(
        abs(sign(ray_dir_screen) - ray_origin_screen) /
        max(abs(ray_dir_screen), eps)
    );
    ray_length =
        min(ray_length,
            max(0.1, exp(-max0(length(ray_origin_view) * 0.025 - 1.0))));

    const float initial_step_scale = step_ratio == 1.0
        ? rcp(float(step_count))
        : (step_ratio - 1.0) / (pow(step_ratio, float(step_count)) - 1.0);
    float step_length = ray_length * initial_step_scale;

    vec3 ray_pos = ray_origin_screen + length(view_pixel_size) * ray_dir_screen;

    bool hit = false;
    bool hit_after_sss = false;
    bool sss_raymarch = has_sss;
    vec3 exit_pos = ray_origin_view;

    for (int i = 0; i < step_count; ++i) {
        step_length *= step_ratio;
        vec3 ray_step = ray_dir_screen * step_length;
        vec3 dithered_pos = ray_pos + dither * ray_step;
        ray_pos += ray_step;

#ifdef LOD_MOD_ACTIVE
        // if (dithered_pos.z < 0.0) {
        //     continue;
        // }
#endif
        // if (clamp01(dithered_pos) != dithered_pos) {
        //     break;
        // }

        // float depth = texelFetch(
        //                   depth_sampler,
        //                   ivec2(dithered_pos.xy * view_res * taau_render_scale),
        //                   0
        // )
        float depth = texture(
                          depth_sampler,
                          vec2(dithered_pos.xy * view_res * taau_render_scale)
        )
                          .x;

        float z_ray = screen_to_view_space_depth(
            projection_matrix_inverse,
            dithered_pos.z
        );
        float z_sample =
            screen_to_view_space_depth(projection_matrix_inverse, depth);

        // bool inside = depth != 0.0 && depth < dithered_pos.z &&
        //     abs(z_tolerance - (z_ray - z_sample)) < z_tolerance;
        bool inside = depth != 0.0 && (dithered_pos.z-depth) < 1000.0  &&
            // abs(z_tolerance - (z_ray - z_sample)) < z_tolerance;
            (z_ray - z_sample) > -10.0;
        hit = inside || hit;

        if (sss_raymarch) {
            if (!inside) {
                exit_pos = dithered_pos;
                sss_raymarch = false;
            }
        }

        else if (!sss_raymarch) {
            // hit_after_sss = inside || hit_after_sss;
            if (hit) {
                break;
            }
        }
    }

    exit_pos = screen_to_view_space(projection_matrix_inverse, exit_pos, true);
    sss_depth =
        hit_after_sss ? -1.0 : max0(distance(ray_origin_view, exit_pos) * 0.2);

    return hit;
}
//chatgpt spat this out, i have not checked what it does yet
bool raymarch_shadow(
    sampler2D depth_sampler,
    mat4 projection_matrix,
    mat4 projection_matrix_inverse,
    vec3 ray_origin_screen,   // screen space origin (uv.z = linear/clip depth?)
    vec3 ray_origin_view,     // view-space origin
    vec3 ray_dir_view,        // normalized view-space direction
    bool has_sss,
    float dither,
    out float sss_depth
) {
    const int step_count = int(SHADOW_SSRT_STEPS);
    const float step_ratio = 1.05; // >=1: 1.0 = uniform steps, >1 geometric
    const float min_step = 0.02;   // minimum step length in view-space units
    // const float max_distance = 100.0; // clamp ray length in view-space
    const float max_distance = 1000.0; // clamp ray length in view-space

    // Pre-normalize ray dir in view-space
    vec3 ray_dir_v = normalize(ray_dir_view);
    float start_dist = 0.0;

    // Compute a safe ray travel distance (in view space). You had a complicated ray_length;
    // a conservative clamp avoids marching enormous ranges that kill precision.
    float ray_length_view = clamp(max_distance, 0.0, max_distance);

    // geometric stepping initial scale (handles step_ratio ~= 1 safely)
    float initial_step;
    if (abs(step_ratio - 1.0) < 1e-6) {
        initial_step = ray_length_view / float(step_count);
    } else {
        // sum of GP: step * (r^n - 1)/(r - 1) = ray_length_view  => step = ...
        initial_step = ray_length_view * (step_ratio - 1.0) / (pow(step_ratio, float(step_count)) - 1.0);
    }
    float step_length = max(initial_step, min_step);

    // start ray position a small offset to avoid self-hit (in view space)
    float cur_dist = start_dist + length(view_pixel_size) * 0.5; // keep your pixel offset idea but in view-space
    vec3 cur_pos_view = ray_origin_view + ray_dir_v * cur_dist;

    bool hit = false;
    bool hit_after_sss = false;
    bool sss_raymarch = has_sss;
    vec3 exit_pos_view = ray_origin_view;

    for (int i = 0; i < step_count; ++i) {
        // ---- march in view space using step_length ----
        vec3 step_v = ray_dir_v * step_length;
        // optionally add a tiny per-sample jitter to reduce banding
        cur_pos_view += step_v * (1.0 + dither * (fract(sin(float(i) * 12.9898) * 43758.5453) - 0.5));
        cur_dist += step_length;

        // project current view-space point to screen (NDC -> uv)
        vec4 clip = projection_matrix * vec4(cur_pos_view, 1.0);
        // avoid division by zero
        if (abs(clip.w) < 1e-6) { break; }
        vec3 ndc = clip.xyz / clip.w;            // -1..1 (GL) or adjust for DX Y range
        vec2 uv = ndc.xy * 0.5 + 0.5;            // 0..1
        float proj_depth = ndc.z * 0.5 + 0.5;   // depends on your depth range; convert to 0..1

        // break if outside screen
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            break;
        }

        // sample depth using bilinear filtering (texture) to avoid coarse texel jumps
        float sceneDepth = texture(depth_sampler, uv).x;
        // convert sampled depth (0..1) to view-space z (same space as cur_pos_view.z)
        float z_ray = -cur_pos_view.z; // assuming camera looks down -Z in view space; adapt if different
        float z_sample = screen_to_view_space_depth(projection_matrix_inverse, sceneDepth);

        // thickness (tolerance) in view-space units - scale with distance
        float thickness = max(0.02, z_ray * 0.01);

        // hit test: sample must be valid and closer than the ray point within tolerance
        bool inside = (sceneDepth > 0.0) && (z_sample + thickness <= z_ray);

        if (sss_raymarch) {
            if (!inside) {
                // we are exiting the scattering volume; store exit
                exit_pos_view = cur_pos_view;
                sss_raymarch = false;
            }
        } else {
            if (inside) {
                hit = true;
                // We can do a small binary-search refinement here if you want.
                break;
            }
        }

        // advance step size for geometric progression (multiply AFTER use)
        step_length *= step_ratio;
        // safety: clamp step_length
        step_length = clamp(step_length, min_step, 2.0 * initial_step);
    }

    sss_depth = hit_after_sss ? -1.0 : max(0.0, distance(ray_origin_view, exit_pos_view) * 0.2);
    return hit;
}

float get_screen_space_shadows(
    vec2 position_screen_xy,
    vec3 position_view,
    float depth,
#ifdef LOD_MOD_ACTIVE
    float depth_lod,
#endif
    float skylight,
    bool has_sss,
    inout float sss_depth
) {
    // Dithering for ray offset
    float dither = texelFetch(noisetex, ivec2(gl_FragCoord.xy) & 511, 0).b;
    dither = r1(frameCounter, dither);
    dither = 0.0;

    // Slightly randomise ray direction to create soft shadows
    vec2 hash = hash2(gl_FragCoord.xy);
    vec3 ray_dir =
        normalize(view_light_dir + 0.03 * uniform_sphere_sample(hash));
        normalize(view_light_dir);

#ifdef LOD_MOD_ACTIVE
    // Which depth map to raymarch depends on distance
    // Closer fragments: use combined depth texture (so MC terrain can cast)
    // Further fragments: use LoD depth texture (maximise precision)

    bool raymarch_combined_depth = length_squared(position_view) <
        // sqr(far + 64.0); // heuristic of 4 chunks overlap
        sqr(far + 0.0); // heuristic of 4 chunks overlap
    bool hit;

    /*
    #ifdef MC_GL_KHR_shader_subgroup
    // Using subgroup ops, we make sure that if any fragments in a warp are
    raymarching the
    // combined depth buffer, they all do, to avoid divergent branches.
    raymarch_combined_depth = subgroupAny(raymarch_combined_depth);
    #endif
    */

    if (raymarch_combined_depth) {
        hit = raymarch_shadow(
            combined_depth_tex,
            combined_projection_matrix,
            combined_projection_matrix_inverse,
            vec3(position_screen_xy, depth),
            position_view,
            ray_dir,
            has_sss,
            dither,
            sss_depth
        );
    } else {
        hit = raymarch_shadow(
            lod_depth_tex,
            lod_projection_matrix,
            lod_projection_matrix_inverse,
            vec3(position_screen_xy, depth_lod),
            position_view,
            ray_dir,
            has_sss,
            dither,
            sss_depth
        );
        // hit = false;
    }
#else
    bool hit = raymarch_shadow(
        depthtex1,
        gbufferProjection,
        gbufferProjectionInverse,
        vec3(position_screen_xy, depth),
        position_view,
        view_light_dir,
        has_sss,
        dither,
        sss_depth
    );
#endif

    return float(!hit) * get_lightmap_light_leak_prevention(skylight);
}

#endif // INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS
