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

# ---------------------------------------------------------------------------
# Custom panels — explicitly pinned to METAL_RENDERER
# ---------------------------------------------------------------------------

class METAL_PT_world_settings(bpy.types.Panel):
    bl_label = "World / Environment"
    bl_idname = "METAL_PT_world_settings"
    bl_space_type = 'PROPERTIES'
    bl_region_type = 'WINDOW'
    bl_context = "world"
    COMPAT_ENGINES = {'METAL_RENDERER'}

    @classmethod
    def poll(cls, context):
        return context.engine in cls.COMPAT_ENGINES

    def draw(self, context):
        layout = self.layout
        world = context.scene.world
        if not world:
            layout.operator("world.new", text="New World")
            return
        if not world.use_nodes:
            layout.prop(world, "use_nodes", text="Use Nodes")
            return

        # Find Environment Texture + Background nodes
        env_node = next((n for n in world.node_tree.nodes if n.type == 'TEX_ENVIRONMENT'), None)
        bg_node  = next((n for n in world.node_tree.nodes if n.type == 'BACKGROUND'), None)

        box = layout.box()
        box.label(text="HDRI / Environment Texture", icon='IMAGE_DATA')
        if env_node:
            box.template_image(env_node, "image", env_node.image_user)
        else:
            box.operator("node.new_node_tree", text="Add Environment Texture node in World Shader")

        box2 = layout.box()
        box2.label(text="Background Strength", icon='LIGHT_SUN')
        if bg_node and 'Strength' in bg_node.inputs:
            box2.prop(bg_node.inputs['Strength'], "default_value", text="Strength")


class METAL_PT_camera_dof(bpy.types.Panel):
    bl_label = "Depth of Field"
    bl_idname = "METAL_PT_camera_dof"
    bl_space_type = 'PROPERTIES'
    bl_region_type = 'WINDOW'
    bl_context = "data"
    COMPAT_ENGINES = {'METAL_RENDERER'}

    @classmethod
    def poll(cls, context):
        return (context.engine in cls.COMPAT_ENGINES and
                context.camera is not None)

    def draw_header(self, context):
        cam = context.camera
        self.layout.prop(cam.dof, "use_dof", text="")

    def draw(self, context):
        layout = self.layout
        cam = context.camera
        dof = cam.dof
        layout.use_property_split = True
        layout.active = dof.use_dof
        layout.prop(dof, "focus_object")
        col = layout.column()
        col.active = dof.focus_object is None
        col.prop(dof, "focus_distance")
        layout.prop(dof, "aperture_fstop")


class METAL_PT_output(bpy.types.Panel):
    bl_label = "Output"
    bl_idname = "METAL_PT_output"
    bl_space_type = 'PROPERTIES'
    bl_region_type = 'WINDOW'
    bl_context = "output"
    COMPAT_ENGINES = {'METAL_RENDERER'}

    @classmethod
    def poll(cls, context):
        return context.engine in cls.COMPAT_ENGINES

    def draw(self, context):
        layout = self.layout
        rd = context.scene.render
        layout.use_property_split = True
        layout.prop(rd, "filepath", text="Output Path")
        layout.prop(rd, "file_format")
        layout.separator()
        layout.prop(rd, "resolution_x", text="Resolution X")
        layout.prop(rd, "resolution_y", text="Resolution Y")
        layout.prop(rd, "resolution_percentage", text="Percentage")
        layout.separator()
        layout.prop(rd, "fps")


CUSTOM_PANELS = (
    METAL_PT_world_settings,
    METAL_PT_camera_dof,
    METAL_PT_output,
)

# ---------------------------------------------------------------------------
# Standard panel discovery (safe version — skips frozen sets)
# ---------------------------------------------------------------------------

def get_standard_panels():
    """Returns Blender built-in panels we want to make compatible."""
    module_names = [
        'properties_render',
        'properties_material',
        'properties_data_light',
        'properties_data_camera',
        'properties_data_mesh',
        'properties_scene',
        'properties_view_layer',
        'properties_object',
        'properties_particle',
    ]
    panels = []
    import importlib
    for name in module_names:
        try:
            mod = importlib.import_module(f'bl_ui.{name}')
            for member_name in dir(mod):
                member = getattr(mod, member_name)
                if hasattr(member, 'COMPAT_ENGINES') and isinstance(member.COMPAT_ENGINES, set):
                    panels.append(member)
        except Exception:
            pass
    return panels


def register():
    properties.register()
    bpy.utils.register_class(MetalRenderEngine)
    for cls in CUSTOM_PANELS:
        bpy.utils.register_class(cls)
    for panel in get_standard_panels():
        try:
            panel.COMPAT_ENGINES.add('METAL_RENDERER')
        except Exception:
            pass


def unregister():
    for panel in get_standard_panels():
        try:
            panel.COMPAT_ENGINES.discard('METAL_RENDERER')
        except Exception:
            pass
    for cls in reversed(CUSTOM_PANELS):
        bpy.utils.unregister_class(cls)
    bpy.utils.unregister_class(MetalRenderEngine)
    properties.unregister()


if __name__ == "__main__":
    register()
