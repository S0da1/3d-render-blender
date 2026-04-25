import bpy

# parse_socket returns (msl_expr_string, is_float3)
# is_float3=True  -> expression returns float3
# is_float3=False -> expression returns float (scalar)

def parse_socket(socket):
    """Recursively evaluates a socket. Returns (msl_str, is_float3)."""
    if not socket.is_linked:
        val = socket.default_value
        if type(val) in [float, int]:
            return (f"{float(val):.5f}", False)
        elif hasattr(val, '__len__') and len(val) >= 3:
            return (f"float3({val[0]:.5f}, {val[1]:.5f}, {val[2]:.5f})", True)
        else:
            return ("0.0", False)

    link = socket.links[0]
    node = link.from_node
    out_name = link.from_socket.name  # e.g. "Color", "Value", "Fac"

    # ---- Image Texture ----
    if node.type == 'TEX_IMAGE':
        img = node.image
        if img:
            # We need to track which texture index this image will have
            # We store it in a list on the context (global textures list)
            if not hasattr(parse_socket, "textures"):
                parse_socket.textures = []
            
            path = bpy.path.abspath(img.filepath_raw or img.filepath)
            if path not in parse_socket.textures:
                parse_socket.textures.append(path)
            
            idx = parse_socket.textures.index(path)
            # MSL: sample from the texture array. texArray starts at index 1 in the shader (after outTexture)
            # Metal texture indices in the array are 0-based relative to the start of the array
            return (f"texArray[{idx}].sample(textureSampler, UV).rgb", True)
        else:
            return ("float3(1.0, 0.0, 1.0)", True) # Pink for missing image

    # ---- Mix RGB / Mix (Blender 4.x) ----
    elif node.type in ('MIX_RGB', 'MIX'):
        if node.type == 'MIX':
            fac_s, fac_v = parse_socket(node.inputs[0])
            col1_s, col1_v = parse_socket(node.inputs[1])
            col2_s, col2_v = parse_socket(node.inputs[2])
        else:
            fac_s, fac_v = parse_socket(node.inputs['Fac'])
            col1_s, col1_v = parse_socket(node.inputs['Color1'])
            col2_s, col2_v = parse_socket(node.inputs['Color2'])
        fac_s = _to_float(fac_s, fac_v)
        col1_s = _to_float3(col1_s, col1_v)
        col2_s = _to_float3(col2_s, col2_v)
        bt = getattr(node, 'blend_type', 'MIX')
        if bt == 'MIX':
            return (f"mix({col1_s}, {col2_s}, {fac_s})", True)
        elif bt == 'ADD':
            return (f"min({col1_s} + {col2_s}, float3(1.0))", True)
        elif bt == 'MULTIPLY':
            return (f"({col1_s} * {col2_s})", True)
        elif bt == 'SUBTRACT':
            return (f"max({col1_s} - {col2_s}, float3(0.0))", True)
        elif bt == 'DIFFERENCE':
            return (f"abs({col1_s} - {col2_s})", True)
        elif bt == 'SCREEN':
            return (f"(1.0 - (1.0 - {col1_s}) * (1.0 - {col2_s}))", True)
        elif bt == 'OVERLAY':
            return (f"mix({col1_s} * {col2_s} * 2.0, 1.0 - 2.0*(1.0-{col1_s})*(1.0-{col2_s}), step(0.5, {col1_s}))", True)
        elif bt == 'DODGE':
            return (f"min({col1_s} / max(1.0 - {col2_s}, 0.0001), float3(1.0))", True)
        elif bt == 'BURN':
            return (f"1.0 - min((1.0 - {col1_s}) / max({col2_s}, 0.0001), float3(1.0))", True)
        elif bt == 'LIGHTEN':
            return (f"max({col1_s}, {col2_s})", True)
        elif bt == 'DARKEN':
            return (f"min({col1_s}, {col2_s})", True)
        elif bt == 'SATURATION':
            return (f"mix({col1_s}, {col2_s}, {fac_s})", True)  # approx
        else:
            return (f"mix({col1_s}, {col2_s}, {fac_s})", True)

    # ---- Math ----
    elif node.type == 'MATH':
        v1, v1_v = parse_socket(node.inputs[0])
        v2, v2_v = parse_socket(node.inputs[1])
        v1 = _to_float(v1, v1_v)
        v2 = _to_float(v2, v2_v)
        op = node.operation
        clamp_val = node.use_clamp
        clamp_wrap = (lambda x: f"clamp({x}, 0.0, 1.0)") if clamp_val else (lambda x: x)
        ops = {
            'ADD': f"({v1} + {v2})",
            'SUBTRACT': f"({v1} - {v2})",
            'MULTIPLY': f"({v1} * {v2})",
            'DIVIDE': f"({v1} / max({v2}, 0.0001))",
            'SINE': f"sin({v1})",
            'COSINE': f"cos({v1})",
            'TANGENT': f"tan({v1})",
            'ARCSINE': f"asin(clamp({v1}, -1.0, 1.0))",
            'ARCCOSINE': f"acos(clamp({v1}, -1.0, 1.0))",
            'ARCTANGENT': f"atan({v1})",
            'ARCTAN2': f"atan2({v1}, {v2})",
            'POWER': f"pow(max({v1}, 0.0), {v2})",
            'LOGARITHM': f"log(max({v1}, 0.0001))",
            'SQRT': f"sqrt(max({v1}, 0.0))",
            'ABSOLUTE': f"abs({v1})",
            'MINIMUM': f"min({v1}, {v2})",
            'MAXIMUM': f"max({v1}, {v2})",
            'ROUND': f"round({v1})",
            'MODULO': f"fmod({v1}, max({v2}, 0.0001))",
            'FLOOR': f"floor({v1})",
            'CEIL': f"ceil({v1})",
            'FRACTION': f"fract({v1})",
            'GREATER_THAN': f"({v1} > {v2} ? 1.0 : 0.0)",
            'LESS_THAN': f"({v1} < {v2} ? 1.0 : 0.0)",
            'SIGN': f"sign({v1})",
            'COMPARE': f"(abs({v1} - {v2}) <= 0.0001 ? 1.0 : 0.0)",
            'SNAP': f"(floor({v1} / max({v2}, 0.0001)) * max({v2}, 0.0001))",
            'PINGPONG': f"(abs(fmod({v1}, 2.0 * max({v2}, 0.0001)) - max({v2}, 0.0001)))",
            'SMOOTH_MIN': f"min({v1}, {v2})",
            'SMOOTH_MAX': f"max({v1}, {v2})",
            'MULTIPLY_ADD': f"({v1} * {v2} + {_to_float(parse_socket(node.inputs[2])[0])})",
            'WRAP': f"fmod({v1}, max({v2}, 0.0001))",
            'TRUNC': f"trunc({v1})",
            'INVERSE_SQRT': f"rsqrt(max({v1}, 0.0001))",
            'EXPONENT': f"exp({v1})",
        }
        result = ops.get(op, v1)
        return (clamp_wrap(result), False)

    # ---- Color Ramp ----
    elif node.type == 'VALTORGB':
        fac_raw, fac_is_vec = parse_socket(node.inputs['Fac'])
        elements = node.color_ramp.elements
        interp = node.color_ramp.interpolation

        if len(elements) == 0:
            return ("float3(0.0)", True)
        elif len(elements) == 1:
            c = elements[0].color
            return (f"float3({c[0]:.5f}, {c[1]:.5f}, {c[2]:.5f})", True)

        # Always need a scalar for comparisons
        fac_scalar = _to_float(fac_raw, fac_is_vec)
        f_var = f"clamp({fac_scalar}, 0.0, 1.0)"

        last = elements[-1]
        expr = f"float3({last.color[0]:.5f}, {last.color[1]:.5f}, {last.color[2]:.5f})"

        for i in range(len(elements) - 2, -1, -1):
            e0 = elements[i]
            e1 = elements[i + 1]
            pos0 = e0.position
            pos1 = e1.position
            c0 = e0.color
            c1 = e1.color
            col0str = f"float3({c0[0]:.5f}, {c0[1]:.5f}, {c0[2]:.5f})"
            col1str = f"float3({c1[0]:.5f}, {c1[1]:.5f}, {c1[2]:.5f})"
            seg_width = pos1 - pos0
            if seg_width < 1e-6:
                seg_expr = col1str
            elif interp == 'CONSTANT':
                seg_expr = col0str
            else:
                seg_expr = f"mix({col0str}, {col1str}, clamp(({f_var} - {pos0:.5f}) / {seg_width:.5f}, 0.0, 1.0))"
            expr = f"(({f_var}) < {pos1:.5f} ? {seg_expr} : {expr})"

        first = elements[0]
        c0 = first.color
        col0str = f"float3({c0[0]:.5f}, {c0[1]:.5f}, {c0[2]:.5f})"
        return (f"(({f_var}) <= {first.position:.5f} ? {col0str} : {expr})", True)

    # ---- Noise Texture ----
    elif node.type == 'TEX_NOISE':
        scale, scale_v = parse_socket(node.inputs['Scale'])
        scale = _to_float(scale, scale_v)
        if out_name == 'Color':
            return (f"float3(msl_noise3d(P * {scale}), msl_noise3d(P * {scale} + 1.7), msl_noise3d(P * {scale} + 3.3))", True)
        else:  # Value
            return (f"msl_noise3d(P * {scale})", False)

    # ---- Voronoi Texture ----
    elif node.type == 'TEX_VORONOI':
        scale, scale_v = parse_socket(node.inputs['Scale'])
        scale = _to_float(scale, scale_v)
        if out_name == 'Color':
            return (f"float3(msl_voronoi3d(P * {scale}), msl_voronoi3d(P * {scale} + 1.3), msl_voronoi3d(P * {scale} + 2.7))", True)
        else:  # Distance
            return (f"msl_voronoi3d(P * {scale})", False)

    # ---- Wave Texture ----
    elif node.type == 'TEX_WAVE':
        scale, scale_v = parse_socket(node.inputs['Scale'])
        scale = _to_float(scale, scale_v)
        wave = f"(sin(P.x * {scale} * 6.28318) * 0.5 + 0.5)"
        return (f"float3({wave})", True)

    # ---- Gradient Texture ----
    elif node.type == 'TEX_GRADIENT':
        return (f"float3(clamp(P.x * 0.5 + 0.5, 0.0, 1.0))", True)

    # ---- Brick Texture ----
    elif node.type == 'TEX_BRICK':
        return ("float3(0.8, 0.8, 0.8)", True)

    # ---- Checker Texture ----
    elif node.type == 'TEX_CHECKER':
        scale, scale_v = parse_socket(node.inputs['Scale'])
        scale = _to_float(scale, scale_v)
        c1_s, c1_v = parse_socket(node.inputs['Color1'])
        c2_s, c2_v = parse_socket(node.inputs['Color2'])
        c1_s = _to_float3(c1_s, c1_v)
        c2_s = _to_float3(c2_s, c2_v)
        checker = f"(fmod(floor(P.x * {scale}) + floor(P.y * {scale}) + floor(P.z * {scale}), 2.0) < 1.0)"
        return (f"({checker} ? {c1_s} : {c2_s})", True)

    # ---- RGB ----
    elif node.type == 'RGB':
        c = node.outputs[0].default_value
        return (f"float3({c[0]:.5f}, {c[1]:.5f}, {c[2]:.5f})", True)

    # ---- Value ----
    elif node.type == 'VALUE':
        v = node.outputs[0].default_value
        return (f"{float(v):.5f}", False)

    # ---- Invert ----
    elif node.type == 'INVERT':
        col_s, col_v = parse_socket(node.inputs['Color'])
        col_s = _to_float3(col_s, col_v)
        fac_s, fac_v = parse_socket(node.inputs['Fac'])
        fac_s = _to_float(fac_s, fac_v)
        return (f"mix({col_s}, 1.0 - {col_s}, {fac_s})", True)

    # ---- Gamma ----
    elif node.type == 'GAMMA':
        col_s, col_v = parse_socket(node.inputs['Color'])
        col_s = _to_float3(col_s, col_v)
        gam_s, gam_v = parse_socket(node.inputs['Gamma'])
        gam_s = _to_float(gam_s, gam_v)
        return (f"pow(max({col_s}, float3(0.0)), float3({gam_s}))", True)

    # ---- Brightness/Contrast ----
    elif node.type == 'BRIGHTCONTRAST':
        col_s, col_v = parse_socket(node.inputs['Color'])
        col_s = _to_float3(col_s, col_v)
        br_s, br_v = parse_socket(node.inputs['Bright'])
        br_s = _to_float(br_s, br_v)
        co_s, co_v = parse_socket(node.inputs['Contrast'])
        co_s = _to_float(co_s, co_v)
        return (f"clamp({col_s} + {br_s} + {co_s} * ({col_s} - 0.5), float3(0.0), float3(1.0))", True)

    # ---- Hue Saturation Value ----
    elif node.type == 'HUE_SAT':
        col_s, _ = parse_socket(node.inputs['Color'])
        v_s, _ = parse_socket(node.inputs['Value'])
        return (_to_float3(col_s) + f" * {_to_float(v_s)}", True)

    # ---- Mapping ----
    elif node.type == 'MAPPING':
        vec_s, vec_v = parse_socket(node.inputs['Vector'])
        location = node.inputs['Location'].default_value
        rotation = node.inputs['Rotation'].default_value
        scale_v = node.inputs['Scale'].default_value
        vec_s = _to_float3(vec_s, vec_v)
        return (f"(({vec_s} - float3({location[0]:.4f},{location[1]:.4f},{location[2]:.4f})) * float3({scale_v[0]:.4f},{scale_v[1]:.4f},{scale_v[2]:.4f}))", True)

    # ---- Texture Coordinate ----
    elif node.type == 'TEX_COORD':
        return ("P", True)

    # ---- Fresnel ----
    elif node.type == 'FRESNEL':
        return ("0.5", False)

    # ---- Layer Weight ----
    elif node.type == 'LAYER_WEIGHT':
        return ("0.5", False)

    # ---- Fallback ----
    return ("float3(0.5, 0.5, 0.5)", True)


def _to_float(expr, is_float3):
    """Convert an MSL expression to a scalar float."""
    if is_float3:
        # Extract luminance or just the x component if it's a vector
        # Using standard coefficients for luminance
        return f"dot({expr}, float3(0.2126, 0.7152, 0.0722))"
    return expr


def _to_float3(expr, is_float3):
    """Ensure an MSL expression is a float3."""
    if is_float3:
        return expr
    return f"float3({expr})"


def generate_msl_file(materials, mat_name_to_index, out_path):
    # Reset textures list for this compile
    parse_socket.textures = []
    
    msl_code = """
// ---------------------------------------------------------
// AUTO-GENERATED JIT BLENDER SHADERS
// ---------------------------------------------------------

// Simple 3D hash — returns float in [0,1]
inline float msl_hash(float3 p) {
    p  = fract( p * 0.3183099 + float3(0.1) );
    p *= 17.0;
    return fract( p.x * p.y * p.z * (p.x + p.y + p.z) );
}

// Value noise
inline float msl_noise3d(float3 x) {
    float3 p = floor(x);
    float3 f = fract(x);
    f = f*f*(3.0-2.0*f);
    return mix(mix(mix( msl_hash(p+float3(0,0,0)), msl_hash(p+float3(1,0,0)), f.x),
                   mix( msl_hash(p+float3(0,1,0)), msl_hash(p+float3(1,1,0)), f.x), f.y),
               mix(mix( msl_hash(p+float3(0,0,1)), msl_hash(p+float3(1,0,1)), f.x),
                   mix( msl_hash(p+float3(0,1,1)), msl_hash(p+float3(1,1,1)), f.x), f.y), f.z);
}

// Voronoi distance
inline float msl_voronoi3d(float3 x) {
    float3 p = floor(x);
    float3 f = fract(x);
    float res = 8.0;
    for(int k=-1; k<=1; k++)
    for(int j=-1; j<=1; j++)
    for(int i=-1; i<=1; i++) {
        float3 b = float3(float(i), float(j), float(k));
        float3 r = b - f + msl_hash(p + b);
        float d = dot(r, r);
        if(d < res) res = d;
    }
    return sqrt(res);
}

// JIT material evaluator
// texArray contains textures 1..N (outTexture is at 0, scene textures start after)
inline float3 evaluate_material_jit(uint matIdx, float3 P, float2 UV, float3 default_albedo, 
                                    sampler textureSampler, array<texture2d<float>, 30> texArray) {
    switch (matIdx) {
"""

    for mat_name, idx in mat_name_to_index.items():
        mat = bpy.data.materials.get(mat_name)
        if not mat or not mat.use_nodes:
            continue

        principled = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
        glass_node = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_GLASS'), None)

        target = principled or glass_node
        if target:
            base_col_inp = target.inputs.get('Base Color') or target.inputs.get('Color')
            if base_col_inp and base_col_inp.is_linked:
                try:
                    compiled_str, is_vec = parse_socket(base_col_inp)
                    # Ensure the result is always float3
                    if not is_vec:
                        compiled_str = f"float3({compiled_str})"
                    msl_code += f"        case {idx}: return {compiled_str};\n"
                except Exception as e:
                    print(f"JIT Compile Error on {mat_name}: {e}")
                    # import traceback; traceback.print_exc()

    msl_code += """
        default: return default_albedo;
    }
    return default_albedo;
}
"""
    with open(out_path, 'w') as f:
        f.write(msl_code)
    
    return parse_socket.textures
