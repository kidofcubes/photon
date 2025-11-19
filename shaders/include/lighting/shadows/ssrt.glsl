#if !defined INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS
#define INCLUDE_LIGHTING_SHADOWS_SSRT_SHADOWS

#include "/include/lighting/shadows/common.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/sampling.glsl"
#include "/include/utility/space_conversion.glsl"

//llm generated clamping max dist function for increasing density of samples when possible, no idea how well it works
float get_clamped_max_dist(mat4 proj, vec3 ray_origin_view, vec3 ray_dir_view, float hard_cap) {
    // 1. Extract Frustum Slopes (tan(FOV / 2)) from the projection matrix
    // P[0][0] is 1/tan(fov_x/2) -> slope_x = 1 / P[0][0]
    // We abs() them to ensure we handle standard and inverted matrices correctly
    float slope_x = 1.0 / abs(proj[0][0]);
    float slope_y = 1.0 / abs(proj[1][1]);

    float min_t = hard_cap;

    // 2. Define the 4 Side Planes of the View Frustum Pyramid
    // In View Space (looking down -Z), the planes are defined as:
    // x = +/- z * slope_x
    // y = +/- z * slope_y
    
    // We iterate 2 axes: X (0) and Y (1)
    // And 2 sides: Positive (Right/Top) and Negative (Left/Bottom)
    
    // Unrolling the loop for clarity and GLSL performance:
    
    vec3 O = ray_origin_view;
    vec3 D = ray_dir_view;

    // --- X Axis (Left/Right) ---
    // Equation: O.x + t*D.x = - (O.z + t*D.z) * slope * side
    // Solves to: t = -(O.x + O.z * slope * side) / (D.x + D.z * slope * side)
    
    // Right Plane (side = 1.0)
    {
        float S = slope_x;
        float num = -(O.x + O.z * S);
        float den =   D.x + D.z * S;
        if (den != 0.0) {
            float t = num / den;
            if (t > 0.0) min_t = min(min_t, t);
        }
    }
    // Left Plane (side = -1.0)
    {
        float S = -slope_x;
        float num = -(O.x + O.z * S);
        float den =   D.x + D.z * S;
        if (den != 0.0) {
            float t = num / den;
            if (t > 0.0) min_t = min(min_t, t);
        }
    }

    // --- Y Axis (Top/Bottom) ---
    
    // Top Plane (side = 1.0)
    {
        float S = slope_y;
        float num = -(O.y + O.z * S);
        float den =   D.y + D.z * S;
        if (den != 0.0) {
            float t = num / den;
            if (t > 0.0) min_t = min(min_t, t);
        }
    }
    // Bottom Plane (side = -1.0)
    {
        float S = -slope_y;
        float num = -(O.y + O.z * S);
        float den =   D.y + D.z * S;
        if (den != 0.0) {
            float t = num / den;
            if (t > 0.0) min_t = min(min_t, t);
        }
    }

    return min_t;
}


bool raymarch_shadow(
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
    const float step_ratio = 1.05; // geometric sample distribution
    float max_ray_length_view = float(SHADOW_SSRT_MAX_RANGE);

#ifndef SHADOW_SSRT_LOCKED
    max_ray_length_view = get_clamped_max_dist(projection_matrix, ray_origin_view, ray_dir_view, 1000.0);
#endif


    float initial_step_length;
    // step_length * (geometric sum of step_ratio) = max_ray_length_view
    // with catch case for small small ratios
    if (abs(step_ratio - 1.0) < 1e-6) {
        initial_step_length = max_ray_length_view / float(step_count);
    } else {
        initial_step_length = max_ray_length_view * (step_ratio - 1.0) / (pow(step_ratio, float(step_count)) - 1.0);
    }
    float step_length = max(initial_step_length,0.02);

    vec3 current_ray_pos_view = ray_origin_view + 
        (normalize(ray_dir_view) * (length(view_pixel_size)*0.5));


    bool hit = false;
    bool hit_after_sss = false;
    bool sss_raymarch = has_sss;
    vec3 exit_pos_view = ray_origin_view;

    for (int i = 0; i < step_count; ++i) {
        vec3 ray_step = ray_dir_view * step_length;
        vec3 dithered_pos_view = current_ray_pos_view + (dither * ray_step);
        current_ray_pos_view += ray_step;

        // project view point onto screen for fetching depth
        vec4 clip = projection_matrix * vec4(current_ray_pos_view, 1.0);
        // avoid division by zero
        if (abs(clip.w) < 1e-6) { break; }
        vec3 ndc = clip.xyz / clip.w;            // -1..1 (GL) or adjust for DX Y range
        vec2 uv = ndc.xy * 0.5 + 0.5;            // 0..1


        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            break;
        }

        //i'm using texelFetch here because i feel like it
        float depth_screen = texelFetch(depth_sampler, ivec2(uv * view_res * taau_render_scale),0).x;
        // float depth_screen = texture(depth_sampler, vec2(uv*taau_render_scale)).x;

        float z_ray_view = -current_ray_pos_view.z;
        float z_sample_view = screen_to_view_space_depth(projection_matrix_inverse, depth_screen);

        bool inside = (depth_screen > 0.0) &&
            z_sample_view + (max(0.02, z_ray_view * 0.01)) <= z_ray_view;
        hit = inside || hit;

        if (sss_raymarch) {
            if (!inside) {
                exit_pos_view = dithered_pos_view;
                // exit_pos_view = current_ray_pos_view;
                sss_raymarch = false;
            }
        }else if (!sss_raymarch) {
            if(inside){
                hit_after_sss = true;
                hit = true;
                break;
            }
        }
        step_length *= step_ratio;
        step_length = clamp(step_length, 0.02, initial_step_length * 2.0);
    }

    sss_depth = hit_after_sss ? -1.0 : max0(distance(ray_origin_view, exit_pos_view) * 0.2);

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

    // Slightly randomise ray direction to create soft shadows
    vec2 hash = hash2(gl_FragCoord.xy);
    vec3 ray_dir =
        normalize(view_light_dir + 0.03 * uniform_sphere_sample(hash));

#ifdef LOD_MOD_ACTIVE
    // Which depth map to raymarch depends on distance
    // Closer fragments: use combined depth texture (so MC terrain can cast)
    // Further fragments: use LoD depth texture (maximise precision)

    vec3 scene_pos = view_to_scene_space(position_view);
    scene_pos.y = 0.0;
    bool raymarch_combined_depth = length_squared(scene_to_view_space(scene_pos)) <
        sqr(far + 64.0); // heuristic of 4 chunks overlap
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
