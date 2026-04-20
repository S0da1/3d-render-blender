bl_info = {
    "name": "Metal Renderer",
    "description": "Apple Silicon Metal Ray Tracing Engine",
    "author": "Antigravity",
    "version": (1, 0),
    "blender": (4, 0, 0),
    "location": "Properties > Render",
    "category": "Render",
}

import bpy
from .engine import MetalRenderEngine
from . import properties

def get_panels():
    from bl_ui import properties_render
    from bl_ui import properties_material
    from bl_ui import properties_data_light
    from bl_ui import properties_data_camera
    panels = []
    for mod in (properties_render, properties_material, properties_data_light, properties_data_camera):
        for member_name in dir(mod):
            member = getattr(mod, member_name)
            if hasattr(member, 'COMPAT_ENGINES'):
                panels.append(member)
    return panels

def register():
    properties.register()
    bpy.utils.register_class(MetalRenderEngine)
    for panel in get_panels():
        panel.COMPAT_ENGINES.add('METAL_RENDERER')

def unregister():
    properties.unregister()
    bpy.utils.unregister_class(MetalRenderEngine)
    for panel in get_panels():
        if 'METAL_RENDERER' in panel.COMPAT_ENGINES:
            panel.COMPAT_ENGINES.remove('METAL_RENDERER')

if __name__ == "__main__":
    register()
