import bpy

class MetalRenderSettings(bpy.types.PropertyGroup):
    samples: bpy.props.IntProperty(
        name="Samples",
        description="Number of samples to accumulate per pixel",
        default=300,
        min=1,
        max=4096
    )
    bounces: bpy.props.IntProperty(
        name="Max Bounces",
        description="Maximum number of light bounces",
        default=12,
        min=1,
        max=32
    )

class MetalMaterialSettings(bpy.types.PropertyGroup):
    albedo: bpy.props.FloatVectorProperty(
        name="Albedo (Color)",
        subtype='COLOR',
        default=(0.8, 0.8, 0.8, 1.0),
        size=4,
        min=0.0, max=1.0
    )
    emission: bpy.props.FloatProperty(
        name="Emission Strength",
        default=0.0,
        min=0.0
    )

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
        layout.prop(settings, "samples")
        layout.prop(settings, "bounces")

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

classes = (
    MetalRenderSettings,
    MetalMaterialSettings,
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
