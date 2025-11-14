/*
This raindrop code was taken from https://www.shadertoy.com/view/ltffzl
(by Martijn Steinrucken aka BigWings) and modified by LexBoosT & ShinoNeiluj

Then taken again by kidofcubes
*/

#if (!defined RAINDROP_ON_SCREEN || ! defined WORLD_OVERWORLD)
vec2 raindropRefraction(vec2 coord) {
	return coord;
}
#endif



#if (defined WORLD_OVERWORLD && defined RAINDROP_ON_SCREEN)
uniform ivec2 eyeBrightnessSmooth;
uniform float rain_factor;
uniform float biome_arid;
uniform float is_snowy;
float rainSmooth = 1.0-biome_arid;
float notColdSmooth = (1.0-biome_may_snow);
float eBS2 = clamp01((eyeBrightnessSmooth.y - 220) * 0.0666);

float dropSpeed = frameTimeCounter * DROP_SPEED;

vec3 N13(float p) {
    vec3 p3 = fract(vec3(p) * vec3(0.1031, 0.11369, 0.13787));
    p3 += dot(p3, p3.yzx + 19.19);

    return fract(vec3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}

vec4 N14(float t) {
    return fract(sin(t * vec4(123.0, 1024.0, 1456.0, 264.0)) * vec4(6547.0, 345.0, 8799.0, 1564.0));
}

float N(float t) {
    return fract(sin(t * 12345.564) * 7658.76);
}

float Saw(float threshold, float t) {
    return smoothstep(0.0, threshold, t) * smoothstep(1.0, threshold, t);
}

vec2 DropLayer2(vec2 uv, float time) {
    vec2 initialUV = uv;

    uv.y += time * 0.75;

    vec2 gridSpacing = vec2(6.0, 1.0);
    vec2 grid = gridSpacing * 2.0;
    vec2 gridId = floor(uv * grid);

    float colShift = N(gridId.x);
    uv.y += colShift;

    gridId = floor(uv * grid);

    vec3 noise = N13(gridId.x * 35.2 + gridId.y * 2376.1);
    vec2 stepUV = fract(uv * grid) - vec2(0.5, 0.0);

    float x = noise.x - 0.5;

    float y = initialUV.y * 20.0;
    float wiggle = sin(y + sin(y));
    x += wiggle * (0.5 - abs(x)) * (noise.z - 0.5);
    x *= 0.7;
    float ti = fract(time + noise.z);
    y = (Saw(0.85, ti) - 0.5) * 0.9 + 0.5;
    vec2 position = vec2(x, y);

    float distance = length((stepUV - position) * gridSpacing.yx);

    float mainDrop = smoothstep(0.4, 0.0, distance);

    float radius = sqrt(smoothstep(1.0, y, stepUV.y));
    float colDistance = abs(stepUV.x - x);
    float trail = smoothstep(0.13 * radius, 0.15 * radius * radius, colDistance);
    float trailFront = smoothstep(-0.02, 0.02, stepUV.y - y);
    trail *= trailFront * radius * radius;

    y = initialUV.y;
    float trail2 = smoothstep(0.2 * radius, 0.0, colDistance);
    float droplets = max(0.0, (sin(y * (1.0 - y) * 120.0) - stepUV.y)) * trail2 * trailFront * noise.z;
    y = fract(y * 10.0) + (stepUV.y - 0.5);
    float distanceToPosition = length(stepUV - vec2(x, y));
    droplets = smoothstep(0.3, 0.0, distanceToPosition);
    float result = mainDrop + droplets * radius * trailFront;

    return vec2(result, trail);
}

float StaticDrops(vec2 uv, float time) {
    uv *= 40.0;

    vec2 gridId = floor(uv);
    uv = fract(uv) - vec2(0.5, 0.5);

    vec3 noise = N13(gridId.x * 107.45 + gridId.y * 3543.654);
    vec2 position = (noise.xy - 0.5) * 0.7;
    float distance = length(uv - position);

    float fade = Saw(0.025, fract(time + noise.z));

    float result = smoothstep(0.3, 0.0, distance) * fract(noise.z * 10.0) * fade;

    return result;
}

vec2 Drops(vec2 uv, float time, float layer0Strength, float layer1Strength, float layer2Strength) {
    float staticDropsStrength = StaticDrops(uv, time) * layer0Strength;
    vec2 layer1Result = DropLayer2(uv, time) * layer1Strength;
    vec2 layer2Result = DropLayer2(uv * 1.85, time) * layer2Strength;

    float combinedResult = staticDropsStrength + layer1Result.x + layer2Result.x;
    combinedResult = smoothstep(0.3, 1.0, combinedResult);

    float trail = max(layer1Result.y * layer0Strength, layer2Result.y * layer1Strength);

    return vec2(combinedResult, trail);
}

vec2 raindropRefraction(vec2 coord) {

    #ifndef RAINDROPS_IN_COLD
    	rainSmooth *= notColdSmooth;
    #endif

    float rainVisibility = eBS2 * rainSmooth * rain_factor;

    if (rainVisibility < 0.1 || isEyeInWater != 0) {
        return coord;
    }

    float rainAmount0 = rainVisibility * STATIC_DROP;
    float rainAmount1 = rainVisibility * DROP_LAYER_1;
    float rainAmount2 = rainVisibility * DROP_LAYER_2;

    vec2 uv = (coord - vec2(0.5)) * vec2(aspectRatio, 1.0);
    float t = dropSpeed;

    float staticDrops = smoothstep(-0.5, 1.0, rainAmount0) * 2.0;
    float layer1 = smoothstep(0.25, 0.75, rainAmount1);
    float layer2 = smoothstep(0.0, 0.5, rainAmount2);

    vec2 c = Drops(uv, t, staticDrops, layer1, layer2);

    vec2 e = vec2(0.001, 0.0);
    float cx = Drops(uv + e, t, staticDrops, layer1, layer2).x;
    float cy = Drops(uv + e.yx, t, staticDrops, layer1, layer2).x;
    vec2 n = vec2(cx - c.x, cy - c.x);

    return coord + n;
}

#endif
