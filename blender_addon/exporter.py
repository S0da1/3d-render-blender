import bpy

def export_scene(depsgraph, filepath):
    with open(filepath, 'w') as f:
        vertex_offset = 1
        uv_offset = 1
        normal_offset = 1
        current_mat = None
        
        for instance in depsgraph.object_instances:
            if instance.is_instance:
                obj = instance.instance_object
                matrix = instance.matrix_world
            else:
                obj = instance.object
                matrix = obj.matrix_world
            
            if obj.type == 'MESH':
                try:
                    # For evaluated objects, to_mesh works directly
                    mesh = obj.to_mesh()
                except RuntimeError:
                    continue
                
                if not mesh:
                    continue
                
                # We need a copy of the mesh to transform it, or just transform it in-place
                try:
                    mesh.transform(matrix)
                except Exception:
                    pass
                
                materials = mesh.materials
                
                uv_layer = mesh.uv_layers.active.data if mesh.uv_layers.active else None
                if hasattr(mesh, "calc_normals_split"):
                    mesh.calc_normals_split()
                
                # Write vertices
                for v in mesh.vertices:
                    co = v.co
                    f.write(f"v {co.x} {co.y} {co.z}\n")
                    
                this_uv_offset = uv_offset
                if uv_layer:
                    for loop in mesh.loops:
                        uv = uv_layer[loop.index].uv
                        f.write(f"vt {uv.x} {uv.y}\n")
                        
                this_normal_offset = normal_offset
                for loop in mesh.loops:
                    if hasattr(loop, 'normal'):
                        n = loop.normal
                    else:
                        n = mesh.vertices[loop.vertex_index].normal
                    f.write(f"vn {n.x} {n.y} {n.z}\n")
                
                # Write faces with material grouping
                for pol in mesh.polygons:
                    mat_name = "Default"
                    if materials and pol.material_index < len(materials):
                        mat = materials[pol.material_index]
                        if mat: mat_name = mat.name
                    
                    if mat_name != current_mat:
                        f.write(f"usemtl {mat_name}\n")
                        current_mat = mat_name
                    
                    verts = pol.vertices
                    loop_start = pol.loop_start
                    # Fan triangulation
                    for i in range(1, len(verts) - 1):
                        v1 = vertex_offset + verts[0]
                        v2 = vertex_offset + verts[i]
                        v3 = vertex_offset + verts[i+1]
                        
                        vt1 = this_uv_offset + loop_start + 0
                        vt2 = this_uv_offset + loop_start + i
                        vt3 = this_uv_offset + loop_start + i + 1
                        
                        vn1 = this_normal_offset + loop_start + 0
                        vn2 = this_normal_offset + loop_start + i
                        vn3 = this_normal_offset + loop_start + i + 1
                        
                        if uv_layer:
                            f.write(f"f {v1}/{vt1}/{vn1} {v2}/{vt2}/{vn2} {v3}/{vt3}/{vn3}\n")
                        else:
                            f.write(f"f {v1}//{vn1} {v2}//{vn2} {v3}//{vn3}\n")
                
                vertex_offset += len(mesh.vertices)
                if uv_layer:
                    uv_offset += len(mesh.loops)
                normal_offset += len(mesh.loops)
                obj.to_mesh_clear()
