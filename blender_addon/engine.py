import bpy
import os
import subprocess
import json
import mathutils
from .exporter import export_scene
from .node_compiler import generate_msl_file

def extract_mtl_map(obj_path):
    mtl_map = {}
    idx = 0
    with open(obj_path, 'r') as f:
        for line in f:
            if line.startswith("usemtl "):
                name = line.strip().split(" ", 1)[1]
                if name not in mtl_map:
                    mtl_map[name] = idx
                    idx += 1
    return mtl_map

class MetalRenderEngine(bpy.types.RenderEngine):
    bl_idname = "METAL_RENDERER"
    bl_label = "Metal Renderer"
    bl_use_preview = False
    bl_use_eevee_viewport = True
    bl_use_shading_nodes_custom = False  # Use standard material nodes
    bl_use_spherical_stereo = False
    bl_use_gpu_context = False

    
    def update(self, data, depsgraph):
        pass
    
    def render(self, depsgraph):
        scene = depsgraph.scene
        scale = scene.render.resolution_percentage / 100.0
        width = int(scene.render.resolution_x * scale)
        height = int(scene.render.resolution_y * scale)
        
        # Temp paths
        temp_dir = bpy.app.tempdir
        obj_path = os.path.join(temp_dir, "metal_export.obj")
        json_path = os.path.join(temp_dir, "scene_data.json")
        img_path = os.path.join(temp_dir, "metal_result.png")
        
        result = self.begin_result(0, 0, width, height)
        layer = result.layers[0]
        
        try:
            # Export scene using our context-safe custom exporter
            export_scene(depsgraph, obj_path)
            
            # --- DoF settings ---
            dof_focal = 10.0
            dof_aperture = 0.0
            if eval_cam := (depsgraph.scene.camera.evaluated_get(depsgraph) if depsgraph.scene.camera else None):
                cam_data = eval_cam.data
                if cam_data.dof.use_dof:
                    dof_focal = cam_data.dof.focus_distance
                    # f-stop -> aperture radius: r = (focal_length_mm / 1000) / (2 * f_stop)
                    dof_aperture = (cam_data.lens / 1000.0) / (2.0 * max(cam_data.dof.aperture_fstop, 0.1))
                    
            # --- World / HDRI ---
            world_hdri = ""
            world = scene.world
            if world and world.use_nodes:
                for node in world.node_tree.nodes:
                    if node.type == 'TEX_ENVIRONMENT' and node.image:
                        img = node.image
                        raw = bpy.path.abspath(img.filepath_raw or img.filepath)
                        if raw:
                            world_hdri = raw
                        break

            metal = scene.metal_render
            scene_data = {
                "settings": {
                    "samples":             metal.samples,
                    "bounces":             metal.bounces,
                    "dof_focal_distance":  dof_focal,
                    "dof_aperture_radius": dof_aperture,
                    "env_strength":        metal.env_strength,
                    "world_hdri_path":     world_hdri,
                    "show_background":     1 if metal.show_background else 0,
                    "firefly_clamp":       metal.firefly_clamp,
                    "vol_density":         getattr(metal, 'vol_density', 0.0),
                    "vol_color":           [metal.vol_color[0], metal.vol_color[1], metal.vol_color[2]] if hasattr(metal, 'vol_color') else [1,1,1],
                    "vol_anisotropy":      getattr(metal, 'vol_anisotropy', 0.0),
                    "vol_falloff":         getattr(metal, 'vol_falloff', 0.2),
                },
                "camera": {},
                "lights": [],
                "materials": {}
            }


            
            # Camera
            eval_cam = depsgraph.scene.camera.evaluated_get(depsgraph) if depsgraph.scene.camera else None
            if eval_cam:
                mat = eval_cam.matrix_world
                pos = mat.translation
                forward = mat @ mathutils.Vector((0.0, 0.0, -1.0))
                up = mat @ mathutils.Vector((0.0, 1.0, 0.0)) - pos
                scene_data["camera"] = {
                    "position": [pos.x, pos.y, pos.z],
                    "target": [forward.x, forward.y, forward.z],
                    "up": [up.x, up.y, up.z],
                    "fov": eval_cam.data.angle
                }
            
            # --- Lights (all types) ---
            import math
            for instance in depsgraph.object_instances:
                obj = instance.object
                if obj.type != 'LIGHT':
                    continue
                light_data = obj.data
                mw = instance.matrix_world
                pos = mw.translation
                color = light_data.color
                power = light_data.energy
                ltype = light_data.type  # POINT, SUN, SPOT, AREA

                entry = {
                    "position": [pos.x, pos.y, pos.z],
                    "color":    [color[0], color[1], color[2]],
                    "power":    power,
                    "type":     ltype,
                }

                if ltype == 'SUN':
                    # Direction = -Z of light in world space
                    fwd = mw.to_3x3() @ mathutils.Vector((0, 0, -1))
                    entry["direction"] = [fwd.x, fwd.y, fwd.z]

                elif ltype == 'SPOT':
                    fwd = mw.to_3x3() @ mathutils.Vector((0, 0, -1))
                    entry["direction"]   = [fwd.x, fwd.y, fwd.z]
                    entry["spot_angle"]  = light_data.spot_size * 0.5  # half-angle in radians
                    entry["spot_blend"]  = light_data.spot_blend

                elif ltype == 'AREA':
                    fwd   = mw.to_3x3() @ mathutils.Vector((0, 0, -1))
                    u_vec = mw.to_3x3() @ mathutils.Vector((1, 0, 0))
                    v_vec = mw.to_3x3() @ mathutils.Vector((0, 1, 0))
                    entry["direction"] = [fwd.x, fwd.y, fwd.z]
                    entry["u_axis"]    = [u_vec.x, u_vec.y, u_vec.z]
                    entry["v_axis"]    = [v_vec.x, v_vec.y, v_vec.z]
                    entry["width"]     = light_data.size
                    entry["height"]    = light_data.size_y if light_data.shape in ('RECTANGLE', 'ELLIPSE') else light_data.size
                    entry["type"]      = "AREA_DISK" if light_data.shape in ('DISK', 'ELLIPSE') else "AREA_RECT"

                scene_data["lights"].append(entry)

                    
            # Materials
            mtl_map = extract_mtl_map(obj_path)
            
            for mat in bpy.data.materials:
                albedo = [0.8, 0.8, 0.8]
                emission = 0.0
                metallic = 0.0
                roughness = 0.5
                transmission = 0.0
                ior = 1.45
                tex_path = ""
                normal_tex_path = ""
                
                if mat.use_nodes:
                    principled = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
                    glass_node = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_GLASS'), None)
                    
                    if principled:
                        base_color = principled.inputs.get('Base Color')
                        if base_color:
                            if base_color.is_linked:
                                link = base_color.links[0]
                                node = link.from_node
                                if node.type == 'TEX_IMAGE' and node.image:
                                    tex_path = bpy.path.abspath(node.image.filepath)
                            else:
                                val = base_color.default_value
                                albedo = [val[0], val[1], val[2]]
                        
                        if 'Emission Strength' in principled.inputs:
                            emission = principled.inputs['Emission Strength'].default_value
                            if type(emission) not in [float, int]:
                                # Sometimes it's a vector in newer principled nodes
                                emission = emission[0] if hasattr(emission, '__getitem__') else 0.0
                        if 'Emission' in principled.inputs and not emission:
                             em_color = principled.inputs['Emission'].default_value
                             emission_intensity = (em_color[0]+em_color[1]+em_color[2])/3.0
                             if emission_intensity > 0: emission = emission_intensity
                        
                        if 'Normal' in principled.inputs and principled.inputs['Normal'].is_linked:
                            norm_link = principled.inputs['Normal'].links[0]
                            if norm_link.from_node.type == 'NORMAL_MAP':
                                map_input = norm_link.from_node.inputs.get('Color')
                                if map_input and map_input.is_linked:
                                    tex_link = map_input.links[0]
                                    if tex_link.from_node.type == 'TEX_IMAGE' and tex_link.from_node.image:
                                        normal_tex_path = bpy.path.abspath(tex_link.from_node.image.filepath)
                        
                        if 'Metallic' in principled.inputs:
                            metallic = principled.inputs['Metallic'].default_value
                        if 'Roughness' in principled.inputs:
                            roughness = principled.inputs['Roughness'].default_value
                        if 'Transmission Weight' in principled.inputs:
                            transmission = principled.inputs['Transmission Weight'].default_value
                        elif 'Transmission' in principled.inputs:
                            transmission = principled.inputs['Transmission'].default_value
                        if 'IOR' in principled.inputs:
                            ior = principled.inputs['IOR'].default_value
                    
                    elif glass_node:
                        transmission = 1.0
                        metallic = 0.0
                        
                        if not tex_path:
                            color_inp = glass_node.inputs.get('Color')
                            if color_inp:
                                if color_inp.is_linked:
                                    link = color_inp.links[0]
                                    node = link.from_node
                                    if node.type == 'TEX_IMAGE' and node.image:
                                        tex_path = bpy.path.abspath(node.image.filepath)
                                else:
                                    val = color_inp.default_value
                                    albedo = [val[0], val[1], val[2]]
                                
                        if 'Roughness' in glass_node.inputs:
                            roughness = glass_node.inputs['Roughness'].default_value
                        if 'IOR' in glass_node.inputs:
                            ior = glass_node.inputs['IOR'].default_value
                            
                else:
                    if hasattr(mat, 'metal_material'):
                        val = mat.metal_material.albedo
                        albedo = [val[0], val[1], val[2]]
                        emission = mat.metal_material.emission
                        is_volumetric = 1 if mat.metal_material.is_volumetric else 0
                        v_dens = mat.metal_material.vol_density
                        v_col = [mat.metal_material.vol_color[0], mat.metal_material.vol_color[1], mat.metal_material.vol_color[2]]
                        
                scene_data["materials"][mat.name] = {
                    "albedo": albedo,
                    "emission": emission,
                    "metallic": metallic,
                    "roughness": roughness,
                    "transmission": transmission,
                    "ior": ior,
                    "texture": tex_path,
                    "normalMap": normal_tex_path,
                    "isVolumetric": is_volumetric if 'is_volumetric' in locals() else 0,
                    "volDensity": v_dens if 'v_dens' in locals() else 0.0,
                    "volColor": v_col if 'v_col' in locals() else [1.0, 1.0, 1.0]
                }

                
            # Sub-task: Generate Dynamic Shader logic
            generated_shaders_path = os.path.join(temp_dir, "GeneratedShaders.metal")
            material_textures = generate_msl_file(bpy.data.materials, mtl_map, generated_shaders_path)
            
            # Record textures so the renderer can load them
            scene_data["material_textures"] = material_textures
            
            with open(json_path, 'w') as f:
                json.dump(scene_data, f)

            # Clean up old render to avoid stale results
            if os.path.exists(img_path):
                try:
                    os.remove(img_path)
                except:
                    pass
                    
            # Call Metal Renderer binary
            addon_dir = os.path.dirname(__file__)
            project_dir = os.path.dirname(addon_dir)
            binary_path = os.path.join(project_dir, "metal_renderer", "metal_renderer")
            
            if not os.path.exists(binary_path):
                # Fallback or error if not found in expected relative location
                print(f"Metal Renderer binary not found at {binary_path}")
                # You might want to look in the same directory as the addon too
                binary_path_alt = os.path.join(addon_dir, "metal_renderer")
                if os.path.exists(binary_path_alt):
                    binary_path = binary_path_alt

            binary_dir = os.path.dirname(binary_path)
            
            self.update_stats("", f"Rendering with Metal ({width}x{height}) ...")
            cmd = [binary_path, obj_path, json_path, img_path, str(width), str(height), generated_shaders_path]
            result_proc = subprocess.run(
                cmd, cwd=binary_dir,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            if result_proc.returncode != 0:
                stdout_txt = result_proc.stdout.decode('utf-8', errors='replace')
                stderr_txt = result_proc.stderr.decode('utf-8', errors='replace')
                print("=== Metal Renderer STDOUT ===")
                print(stdout_txt)
                print("=== Metal Renderer STDERR ===")
                print(stderr_txt)
                raise RuntimeError(f"Metal renderer exited with code {result_proc.returncode}. See Blender console for details.")
            
            # Read the PNG back
            layer.load_from_file(img_path)
            
        except Exception as e:
            import traceback
            traceback.print_exc()
            print(f"Metal Renderer Error: {e}")
            self.error_set(f"Metal Renderer Error: {e}")
            
        finally:
            self.end_result(result)
