import bpy

class MetalRenderSettings(bpy.types.PropertyGroup):
    samples: bpy.props.IntProperty(
        name="Samples",
        description="Number of samples to accumulate per pixel",
        default=300, min=1, max=4096
    )
    bounces: bpy.props.IntProperty(
        name="Max Bounces",
        description="Maximum number of light bounces",
        default=12, min=1, max=32
    )
    show_background: bpy.props.BoolProperty(
        name="Show Background",
        description="Show the HDRI / environment as the render background. Disable for transparent background",
        default=True
    )
    firefly_clamp: bpy.props.FloatProperty(
        name="Firefly Clamp",
        description="Maximum luminance per sample. Lower values reduce bright speckles on glass/metals (0 = disabled)",
        default=10.0, min=0.0, max=1000.0
    )
    env_strength: bpy.props.FloatProperty(
        name="Environment Strength",
        description="Overall brightness multiplier for the world / HDRI",
        default=1.0, min=0.0, max=100.0
    )
    hdri_path: bpy.props.StringProperty(
        name="HDRI File",
        description="Select an .hdr or .exr file to light your scene",
        subtype='FILE_PATH'
    )
    # Global Volume (Fog)
    vol_density: bpy.props.FloatProperty(
        name="Density",
        description="Global fog density. 0 = disabled",
        default=0.1, min=0.0, max=10.0
    )
    vol_color: bpy.props.FloatVectorProperty(
        name="Scattering Color",
        subtype='COLOR',
        default=(1.0, 1.0, 1.0),
        size=3, min=0.0, max=1.0
    )
    vol_anisotropy: bpy.props.FloatProperty(
        name="Anisotropy (G)",
        description="Controls scattering direction. 0 = uniform, >0 = forward (halos), <0 = backward",
        default=0.0, min=-0.99, max=0.99
    )
    vol_falloff: bpy.props.FloatProperty(
        name="Height Falloff",
        description="How quickly fog thins as you go up. 0 = infinite wall, higher = ground fog",
        default=0.2, min=0.0, max=10.0
    )


class METAL_OT_setup_hdri(bpy.types.Operator):
    """Automatically setup World nodes for the selected HDRI"""

    bl_idname = "metal.setup_hdri"
    bl_label = "Load & Setup HDRI"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        settings = context.scene.metal_render
        if not settings.hdri_path:
            self.report({'ERROR'}, "No file selected!")
            return {'CANCELLED'}

        # Ensure World exists
        if not context.scene.world:
            context.scene.world = bpy.data.worlds.new("Metal World")
        
        world = context.scene.world
        world.use_nodes = True
        nodes = world.node_tree.nodes
        links = world.node_tree.links
        nodes.clear()

        # Create nodes
        node_env = nodes.new(type='ShaderNodeTexEnvironment')
        node_bg  = nodes.new(type='ShaderNodeBackground')
        node_out = nodes.new(type='ShaderNodeOutputWorld')

        # Load image
        try:
            img = bpy.data.images.load(settings.hdri_path)
            node_env.image = img
        except Exception as e:
            self.report({'ERROR'}, f"Failed to load image: {e}")
            return {'CANCELLED'}

        # Link nodes
        links.new(node_env.outputs['Color'], node_bg.inputs['Color'])
        links.new(node_bg.outputs['Background'], node_out.inputs['Surface'])

        # Align nodes nicely
        node_env.location = (-300, 0)
        node_bg.location = (0, 0)
        node_out.location = (200, 0)

        self.report({'INFO'}, "HDRI Setup Complete!")
        return {'FINISHED'}


class METAL_PT_render_settings(bpy.types.Panel):
    bl_label = "Metal Path Tracer"
    bl_space_type = 'PROPERTIES'
    bl_region_type = 'WINDOW'
    bl_context = "render"

    @classmethod
    def poll(cls, context):
        return context.scene.render.engine == 'METAL_RENDERER'

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        layout.use_property_decorate = False
        settings = context.scene.metal_render

        # Sampling
        col = layout.column(heading="Sampling")
        col.prop(settings, "samples")
        col.prop(settings, "bounces")

        layout.separator()

        # Environment
        col = layout.column(heading="Environment")
        col.prop(settings, "hdri_path", text="HDRI File")
        col.operator("metal.setup_hdri", text="Apply HDRI to World", icon='WORLD_DATA')
        
        row = col.row(align=True)
        row.prop(settings, "show_background", text="Show Background", toggle=True,
                 icon='IMAGE_BACKGROUND' if settings.show_background else 'IMAGE_ALPHA')
        col.prop(settings, "env_strength")

        layout.separator()

        # Volume (Fog)
        col = layout.column(heading="Global Fog")
        col.prop(settings, "vol_density")
        col.prop(settings, "vol_color")
        col.prop(settings, "vol_anisotropy")
        col.prop(settings, "vol_falloff")

        layout.separator()

        # Quality
        col = layout.column(heading="Quality")
        col.prop(settings, "firefly_clamp")


class MetalMaterialSettings(bpy.types.PropertyGroup):
    albedo: bpy.props.FloatVectorProperty(
        name="Albedo (Color)",
        subtype='COLOR',
        default=(0.8, 0.8, 0.8, 1.0),
        size=4, min=0.0, max=1.0
    )
    emission: bpy.props.FloatProperty(
        name="Emission Strength",
        default=0.0,
        min=0.0
    )
    # Local Volume
    is_volumetric: bpy.props.BoolProperty(
        name="Is Volumetric",
        description="If enabled, this object acts as a container for fog (transparent surface)",
        default=False
    )
    vol_density: bpy.props.FloatProperty(
        name="Volume Density",
        default=0.5, min=0.0, max=10.0
    )
    vol_color: bpy.props.FloatVectorProperty(
        name="Volume Color",
        subtype='COLOR',
        default=(1.0, 1.0, 1.0),
        size=3, min=0.0, max=1.0
    )


class METAL_PT_material_settings(bpy.types.Panel):
    bl_label = "Metal Material"
    bl_space_type = 'PROPERTIES'
    bl_region_type = 'WINDOW'
    bl_context = "material"

    @classmethod
    def poll(cls, context):
        return context.scene.render.engine == 'METAL_RENDERER' and context.material

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        settings = context.material.metal_material
        
        layout.prop(settings, "albedo")
        layout.prop(settings, "emission")
        
        layout.separator()
        layout.prop(settings, "is_volumetric")
        if settings.is_volumetric:
            layout.prop(settings, "vol_density")
            layout.prop(settings, "vol_color")



classes = (
    MetalRenderSettings,
    MetalMaterialSettings,
    METAL_OT_setup_hdri,
    METAL_PT_render_settings,
    METAL_PT_material_settings,
)

def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.metal_render = bpy.props.PointerProperty(type=MetalRenderSettings)
    bpy.types.Material.metal_material = bpy.props.PointerProperty(type=MetalMaterialSettings)

def unregister():
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
    del bpy.types.Scene.metal_render
    del bpy.types.Material.metal_material
