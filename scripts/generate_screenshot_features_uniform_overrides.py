from itertools import batched

uniforms = [
    "float", "DOF_INTENSITY",

    "float", "WEATHER_TEMPERATURE_BIAS",
    "float", "WEATHER_HUMIDITY_BIAS",
    "float", "WEATHER_WIND_BIAS",
    "float", "WEATHER_TEMPERATURE_VARIATION_SPEED",
    "float", "WEATHER_HUMIDITY_VARIATION_SPEED",
    "float", "WEATHER_WIND_VARIATION_SPEED",

    "float", "SWAY_STRENGTH",
    "float", "SWAY_SPACE_VARIATION_STRENGTH",
    "float", "SWAY_SPACE_VARIATION_DIRECTION",
    "float", "SWAY_TIME_VARIATION",
    "float", "SWAY_ANGLE"
]
print("""
#ifdef SCREENSHOT_FEATURES
""")

for type_name, uniform_name in batched(uniforms, n=2):
    print(f"""
#ifdef {uniform_name}
#undef {uniform_name}
uniform {type_name} {uniform_name};
#endif
""")
print("""
#endif
""")
