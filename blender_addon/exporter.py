import bpy
import os
import mathutils

def export_scene(depsgraph, filepath):
    # Context-safe manual exporter with optimization
    with open(filepath, 'w') as f:
        vertex_offset = 1
        uv_offset = 1
        normal_offset = 1
        
        for instance in depsgraph.object_instances:
            obj = instance.object
            if obj.type != 'MESH':
                continue
                
            matrix = instance.matrix_world
            
            try:
                mesh = obj.to_mesh()
            except:
                continue
            
            if not mesh:
                continue
                
            mesh.transform(matrix)
            mesh.calc_loop_triangles()
            
            # Use fast bulk data access
            verts = mesh.vertices
            for v in verts:
                co = v.co
                f.write(f"v {co.x:.6f} {co.y:.6f} {co.z:.6f}\n")
            
            uv_layer = mesh.uv_layers.active.data if mesh.uv_layers.active else None
            if uv_layer:
                for loop in mesh.loops:
                    uv = uv_layer[loop.index].uv
                    f.write(f"vt {uv.x:.6f} {uv.y:.6f}\n")
            
            for loop in mesh.loops:
                n = loop.normal
                f.write(f"vn {n.x:.4f} {n.y:.4f} {n.z:.4f}\n")
            
            # Grouping
            mat_name = "Default"
            if mesh.materials and len(mesh.materials) > 0:
                m = mesh.materials[0]
                if m: mat_name = m.name
            f.write(f"usemtl {mat_name}\n")
            
            this_uv_off = uv_offset
            this_v_off = vertex_offset
            this_vn_off = normal_offset
            
            for tri in mesh.loop_triangles:
                # Triangles only for the renderer
                v1, v2, v3 = [this_v_off + mesh.loops[i].vertex_index for i in tri.loops]
                vn1, vn2, vn3 = [this_vn_off + i for i in tri.loops]
                
                if uv_layer:
                    vt1, vt2, vt3 = [this_uv_off + i for i in tri.loops]
                    f.write(f"f {v1}/{vt1}/{vn1} {v2}/{vt2}/{vn2} {v3}/{vt3}/{vn3}\n")
                else:
                    f.write(f"f {v1}//{vn1} {v2}//{vn2} {v3}//{vn3}\n")
            
            vertex_offset += len(mesh.vertices)
            uv_offset += len(mesh.loops)
            normal_offset += len(mesh.loops)
            
            obj.to_mesh_clear()
