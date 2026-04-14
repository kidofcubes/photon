/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/c2b_dof_composite
  Composite near/far DoF layers onto the scene.

  colortex1  (RGBA16 UNORM): far-blurred color (Reinhard-encoded) + far alpha
  colortex13 (RGBA16F):      near-blurred color (HDR) + near alpha

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

layout(location = 0) out vec3 scene_color;

/* RENDERTARGETS: 0 */

in vec2 uv;

uniform sampler2D colortex0;   // original scene color
uniform sampler2D colortex1;   // far blur layer (Reinhard encoded rgb, alpha in a)
uniform sampler2D colortex13;  // near blur layer (HDR rgb, alpha in a)

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);

    vec3 original    = texelFetch(colortex0,  texel, 0).rgb;
    vec4 far_data    = texelFetch(colortex1,  texel, 0);
    vec4 near_data   = texelFetch(colortex13, texel, 0);

    // Inverse Reinhard: x/(1-x). Guard against values at or above 1.0
    // (can occur at the RGBA16 clamp boundary for very bright samples)
    vec3  far_blurred = far_data.rgb / max(vec3(1.0) - far_data.rgb, vec3(1e-5));
    float far_alpha   = far_data.a;

    vec3  near_blurred = near_data.rgb;
    float near_alpha   = near_data.a;

    // Composite: far layer first (background), near layer on top (foreground bleeding)
    vec3 result = mix(original,  far_blurred,  far_alpha);
    result      = mix(result,    near_blurred, near_alpha);

    scene_color = result;
}

#ifndef DOF
#error "This program should be disabled if Depth of Field is disabled"
#endif
