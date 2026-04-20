import bpy
import os
import subprocess
import json
import mathutils
from .exporter import export_scene

class MetalRenderEngine(bpy.types.RenderEngine):
    bl_idname = "METAL_RENDERER"
    bl_label = "Metal Renderer"
    bl_use_preview = False
    
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
            
            # Export advanced JSON data (Camera, Lights, Materials, Settings)
            scene_data = {
                "settings": {
                    "samples": scene.metal_render.samples,
                    "bounces": scene.metal_render.bounces
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
            
            # Lights
            for instance in depsgraph.object_instances:
                obj = instance.object
                if obj.type == 'LIGHT' and obj.data.type == 'POINT':
                    pos = instance.matrix_world.translation
                    color = obj.data.color
                    power = obj.data.energy
                    scene_data["lights"].append({
                        "position": [pos.x, pos.y, pos.z],
                        "color": [color[0], color[1], color[2]],
                        "power": power
                    })
                    
            # Materials
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
                        
                scene_data["materials"][mat.name] = {
                    "albedo": albedo,
                    "emission": emission,
                    "metallic": metallic,
                    "roughness": roughness,
                    "transmission": transmission,
                    "ior": ior,
                    "texture": tex_path,
                    "normalMap": normal_tex_path
                }
                
            with open(json_path, 'w') as f:
                json.dump(scene_data, f)
            
            # Call Metal Renderer binary
            binary_path = "/Users/maxencejaffeux/.gemini/antigravity/scratch/mac-metal-renderer/metal_renderer/metal_renderer"
            
            binary_dir = os.path.dirname(binary_path)
            
            self.update_stats("", f"Rendering with Metal ({width}x{height}) ...")
            cmd = [binary_path, obj_path, json_path, img_path, str(width), str(height)]
            subprocess.run(cmd, check=True, cwd=binary_dir)
            
            # Read the PNG back
            layer.load_from_file(img_path)
            
        except Exception as e:
            import traceback
            traceback.print_exc()
            print(f"Metal Renderer Error: {e}")
            self.error_set(f"Metal Renderer Error: {e}")
            
        finally:
            self.end_result(result)
