// FROM ASTRALEX

float lexDepth(sampler2D depthtex, vec2 coord) {
    return texture2D(depthtex, coord).r;
}

vec3 fullborder(vec3 color, sampler2D depthtex, vec2 texCoord, float viewWidth, float viewHeight, float near, float far) {

    float dtresh = 1.0 / (far - near) / (5000.0 * FULL_BORDER_RAIDUS);
    vec4 dc = vec4(lexDepth(depthtex, texCoord));

    vec3 border = vec3(1.0 / viewWidth, 1.0 / viewHeight, 0.0) * FULL_BORDER_SIZE;
    vec4 sa = vec4(lexDepth(depthtex, texCoord + vec2(-border.x, -border.y)),
                   lexDepth(depthtex, texCoord + vec2(border.x, -border.y)),
                   lexDepth(depthtex, texCoord + vec2(-border.x, border.z)),
                   lexDepth(depthtex, texCoord + vec2(border.z, border.y)));
    vec4 sb = vec4(lexDepth(depthtex, texCoord + vec2(border.x, border.y)),
                   lexDepth(depthtex, texCoord + vec2(-border.x, border.y)),
                   lexDepth(depthtex, texCoord + vec2(border.x, border.z)),
                   lexDepth(depthtex, texCoord + vec2(border.z, -border.y)));
    vec4 dd = abs(2.0 * dc - sa - sb) - dtresh;
    dd = step(dd.xyzw, vec4(0.0));
    float e = clamp(dot(dd, vec4(0.25)), 0.0, 1.0);

    return color * e;
}
