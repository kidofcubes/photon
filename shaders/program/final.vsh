/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/program/final.glsl:
  CAS, dithering, debug views

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

uniform mat4 gbufferModelView;
uniform vec3 sunPosition;

out vec2 uv;
flat out vec3 upVec, sunVec;
out float SdotU;

void main() {
	uv = gl_MultiTexCoord0.xy;

  upVec = normalize(gbufferModelView[1].xyz);
  sunVec = normalize(sunPosition);
  float SdotU = dot(sunVec, upVec);

	gl_Position = vec4(gl_Vertex.xy * 2.0 - 1.0, 0.0, 1.0);
}

