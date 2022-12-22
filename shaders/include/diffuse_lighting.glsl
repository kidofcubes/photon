#if !defined DIFFUSE_LIGHTING_INCLUDED
#define DIFFUSE_LIGHTING_INCLUDED

#include "bsdf.glsl"
#include "material.glsl"
#include "palette.glsl"
#include "phase_functions.glsl"
#include "utility/fast_math.glsl"
#include "utility/spherical_harmonics.glsl"

//----------------------------------------------------------------------------//
#if   defined WORLD_OVERWORLD

const vec3  blocklight_color     = from_srgb(vec3(BLOCKLIGHT_R, BLOCKLIGHT_G, BLOCKLIGHT_B)) * BLOCKLIGHT_I;
const float blocklight_scale     = 10.0;
const float emission_scale       = 40.0;
const float sss_density          = 16.0;
const float sss_scale            = 5.5;
const float metal_diffuse_amount = 0.25; // Scales diffuse lighting on metals, ideally this would be zero but purely specular metals don't play well with SSR
const float night_vision_scale   = 1.5;

vec3 sss_approx(vec3 albedo, float sss_amount, float sheen_amount, float sss_depth, float LoV) {
	if (sss_amount < eps) return vec3(0.0);

	vec3 coeff = albedo * inversesqrt(dot(albedo, luminance_weights) + eps);
	     coeff = clamp01(0.75 * coeff);
	     coeff = (1.0 - coeff) * sss_density / sss_amount;

	float phase = mix(isotropic_phase, henyey_greenstein_phase(-LoV, 0.7), 0.33);

	vec3 sss = sss_scale * phase * exp2(-coeff * sss_depth) * dampen(sss_amount) * pi;
	vec3 sheen = 0.5 * rcp(albedo + eps) * exp2(-0.5 * coeff * sss_depth) * henyey_greenstein_phase(-LoV, 0.8);

	return sss + sheen * sheen_amount;
}

vec3 get_diffuse_lighting(
	Material material,
	vec3 normal,
	vec3 flat_normal,
	vec3 bent_normal,
	vec3 shadows,
	vec2 light_access,
	float ao,
	float sss_depth,
	float NoL,
	float NoV,
	float NoH,
	float LoV
) {
	vec3 lighting = vec3(0.0);

	// Sunlight/moonlight

	float diffuse = lift(max0(NoL), 0.33) * (1.0 - 0.5 * material.sss_amount) * dampen(ao) * mix(ao * ao, 1.0, NoL * NoL);
	vec3 bounced = 0.08 * (1.0 - shadows * max0(NoL)) * (1.0 - 0.33 * max0(normal.y)) * pow1d5(ao + eps) * pow4(light_access.y);
	vec3 sss = sss_approx(material.albedo, material.sss_amount, material.sheen_amount, sss_depth, LoV);

	lighting += light_color * (diffuse * shadows + bounced + sss);

	// Skylight

#ifdef SH_SKYLIGHT
	vec3 skylight = sh_evaluate_irradiance(sky_sh, bent_normal, ao);
#else
	vec3 horizon_color = mix(sky_samples[1], sky_samples[2], dot(bent_normal.xz, moon_dir.xz) * 0.5 + 0.5);
	     horizon_color = mix(horizon_color, mix(sky_samples[1], sky_samples[2], step(sun_dir.y, 0.5)), abs(bent_normal.y) * (time_noon + time_midnight));

	float horizon_weight = 0.166 * (time_noon + time_midnight) + 0.03 * (time_sunrise + time_sunset);

	vec3 skylight  = mix(sky_samples[0] * 1.3, horizon_color, horizon_weight);
	     skylight  = mix(horizon_color * 0.2, skylight, clamp01(abs(bent_normal.y)) * 0.3 + 0.7);
	     skylight *= 1.0 - 0.75 * clamp01(-bent_normal.y);
	     skylight *= 1.0 + 0.33 * clamp01(flat_normal.y) * (1.0 - shadows.x) * (time_noon + time_midnight);
	     skylight *= ao * pi;
#endif

	float skylight_access = sqr(light_access.y);

	lighting += skylight * skylight_access;

	// Blocklight

	float vanilla_diffuse = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y)); // Random directional shading to make faces easier to distinguish

	float blocklight_access  = 0.3 * pow5(light_access.x) + 0.12 * sqr(light_access.x) + 0.1 * dampen(light_access.x); // Base falloff
	      blocklight_access *= mix(ao, 1.0, clamp01(blocklight_access * 2.0));                          // Stronger AO further from the light source
		  blocklight_access *= 1.0 - 0.2 * time_noon * light_access.y - 0.2 * light_access.y;                      // Reduce blocklight intensity in daylight
		  blocklight_access += 2.5 * pow12(light_access.x);                                                 // Strong highlight around the light source, visible even in the daylight

	lighting += (blocklight_access * vanilla_diffuse) * (blocklight_scale * blocklight_color);

	lighting += material.emission * emission_scale;

	// Cave lighting

	lighting += CAVE_LIGHTING_I * vanilla_diffuse * ao * (1.0 - skylight_access);
	lighting += nightVision * night_vision_scale * vanilla_diffuse * ao;

	return max0(lighting) * material.albedo * rcp_pi * mix(1.0, metal_diffuse_amount, float(material.is_metal));
}

//----------------------------------------------------------------------------//
#elif defined WORLD_NETHER

//----------------------------------------------------------------------------//
#elif defined WORLD_END

#endif

#endif // DIFFUSE_LIGHTING_INCLUDED
