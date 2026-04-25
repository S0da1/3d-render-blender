#import "Renderer.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MetalKit/MetalKit.h>
#include <fstream>
#include <sstream>
#include <vector>
#include <iostream>
#include <algorithm>
#include <cstring>

struct Uniforms {
    simd_float3 cameraPos;
    simd_float3 cameraTarget;
    simd_float3 cameraUp;
    float fov;
    uint width;
    uint height;
    uint samples;
    uint bounces;
    uint lightCount;
    float gridMinX;
    float gridMinY;
    float gridMinZ;
    float gridCellSize;
    uint gridResolution;
    uint gridTotalCells;
    float causticRadius;
    uint maxPhotons;
    // Depth of Field
    float focalDistance;
    float apertureRadius;
    // Environment
    float envStrength;
    uint hasHDRI;
    // Firefly clamping
    float fireflyClamp;
    // Background visibility
    uint showBackground;
    // Global Volume
    float volDensity;
    simd_float3 volColor;
    float volAnisotropy;
    float volFalloff;
};


struct LightData {
    simd_float3 position;
    simd_float3 color;
    float       power;
    simd_float3 direction;
    simd_float3 u_axis;
    simd_float3 v_axis;
    float       width;
    float       height;
    float       spotAngle;
    float       spotBlend;
    uint32_t    type;   // 0=point, 1=sun, 2=spot, 3=area_rect, 4=area_disk
};

struct MaterialData {
    simd_float3 albedo;
    float emission;
    float metallic;
    float roughness;
    float transmission;
    float ior;
    int baseColorIndex;
    int normalMapIndex;
    // Volume properties
    uint32_t isVolumetric;
    float volDensity;
    simd_float3 volColor;
};

Renderer::Renderer() {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        std::cerr << "Metal is not supported on this device" << std::endl;
        exit(1);
    }
    _commandQueue = [_device newCommandQueue];
    // Pipelines are compiled JIT in handleScene() after dynamic shader concatenation
}


Renderer::~Renderer() {}

bool Renderer::loadSimpleObj(const std::string& filepath, SceneData& outData, std::unordered_map<std::string, uint32_t>& mtlMap) {
    std::ifstream file(filepath);
    if (!file.is_open()) return false;
    
    std::vector<simd_float3> temp_v;
    std::vector<simd_float2> temp_vt;
    std::vector<simd_float3> temp_vn;
    
    std::string currentMtl = "";
    std::unordered_map<std::string, uint32_t> uniqueVertices;
    std::vector<VertexData> out_vertices;
    std::vector<uint32_t> indices;
    std::vector<uint32_t> matIndices;
    
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '#') continue;
        const char* p = line.c_str();
        while (*p == ' ') p++; // Skip leading whitespace
        
        if (p[0] == 'v' && p[1] == ' ') {
            float x, y, z;
            if (sscanf(p + 2, "%f %f %f", &x, &y, &z) == 3)
                temp_v.push_back(simd_make_float3(x, y, z));
        } else if (p[0] == 'v' && p[1] == 't') {
            float u, v;
            if (sscanf(p + 3, "%f %f", &u, &v) == 2)
                temp_vt.push_back(simd_make_float2(u, v));
        } else if (p[0] == 'v' && p[1] == 'n') {
            float nx, ny, nz;
            if (sscanf(p + 3, "%f %f %f", &nx, &ny, &nz) == 3)
                temp_vn.push_back(simd_make_float3(nx, ny, nz));
        } else if (p[0] == 'u' && strncmp(p, "usemtl", 6) == 0) {
            char mtlName[256];
            if (sscanf(p + 7, "%255s", mtlName) == 1) {
                currentMtl = mtlName;
                if (mtlMap.find(currentMtl) == mtlMap.end()) {
                    mtlMap[currentMtl] = (uint32_t)mtlMap.size();
                }
            }
        } else if (p[0] == 'f' && p[1] == ' ') {
            char v1s[64], v2s[64], v3s[64];
            if (sscanf(p + 2, "%63s %63s %63s", v1s, v2s, v3s) == 3) {
                auto processVertex = [&](const char* vertexStr) -> uint32_t {
                    if (uniqueVertices.count(vertexStr) == 0) {
                        uniqueVertices[vertexStr] = (uint32_t)out_vertices.size();
                        
                        int v_idx = 0, vt_idx = 0, vn_idx = 0;
                        if (strstr(vertexStr, "//")) {
                            sscanf(vertexStr, "%d//%d", &v_idx, &vn_idx);
                        } else if (std::count(vertexStr, vertexStr + strlen(vertexStr), '/') == 2) {
                            sscanf(vertexStr, "%d/%d/%d", &v_idx, &vt_idx, &vn_idx);
                        } else {
                            sscanf(vertexStr, "%d/%d", &v_idx, &vt_idx);
                        }
                        
                        VertexData vd;
                        vd.position = (v_idx > 0 && (size_t)v_idx <= temp_v.size()) ? temp_v[v_idx - 1] : simd_make_float3(0,0,0);
                        vd.uv = (vt_idx > 0 && (size_t)vt_idx <= temp_vt.size()) ? temp_vt[vt_idx - 1] : simd_make_float2(0,0);
                        vd.normal = (vn_idx > 0 && (size_t)vn_idx <= temp_vn.size()) ? temp_vn[vn_idx - 1] : simd_make_float3(0,1,0);
                        out_vertices.push_back(vd);
                    }
                    return uniqueVertices[vertexStr];
                };
                indices.push_back(processVertex(v1s));
                indices.push_back(processVertex(v2s));
                indices.push_back(processVertex(v3s));
                matIndices.push_back(mtlMap[currentMtl]);
            }
        }
    }
    
    outData.vertexCount = out_vertices.size();
    outData.indexCount = indices.size();
    
    size_t vAlloc = std::max((size_t)1, outData.vertexCount);
    size_t iAlloc = std::max((size_t)1, outData.indexCount);
    size_t mAlloc = std::max((size_t)1, matIndices.size());
    
    outData.vertices = new VertexData[vAlloc];
    outData.indices = new uint32_t[iAlloc];
    outData.materialIndices = new uint32_t[mAlloc];
    
    if (outData.vertexCount > 0) std::copy(out_vertices.begin(), out_vertices.end(), outData.vertices);
    if (outData.indexCount > 0) std::copy(indices.begin(), indices.end(), outData.indices);
    if (matIndices.size() > 0) std::copy(matIndices.begin(), matIndices.end(), outData.materialIndices);
    
    _vertexBuffer = [_device newBufferWithBytes:outData.vertices length:vAlloc * sizeof(VertexData) options:MTLResourceStorageModeShared];
    _indexBuffer  = [_device newBufferWithBytes:outData.indices length:iAlloc * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    
    return true;
}

bool Renderer::loadSceneData(const std::string& jsonPath, SceneData& outData, const std::unordered_map<std::string, uint32_t>& mtlMap) {
    NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:jsonPath.c_str()]];
    if (!data) return false;
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!json) return false;

    _sceneTextures.clear();
    
    // New uniform fields with defaults
    float dof_focal_distance = 10.0f;
    float dof_aperture_radius = 0.0f;
    float env_strength = 1.0f;
    bool has_hdri = false;
    float firefly_clamp = 10.0f;
    std::string hdri_path = "";
    
    NSDictionary* settingsDict = json[@"settings"];
    if (settingsDict) {
        outData.samples = [settingsDict[@"samples"] intValue];
        outData.bounces = [settingsDict[@"bounces"] intValue];
        if (settingsDict[@"dof_focal_distance"])
            dof_focal_distance = [settingsDict[@"dof_focal_distance"] floatValue];
        if (settingsDict[@"dof_aperture_radius"])
            dof_aperture_radius = [settingsDict[@"dof_aperture_radius"] floatValue];
        if (settingsDict[@"env_strength"])
            env_strength = [settingsDict[@"env_strength"] floatValue];
        if (settingsDict[@"firefly_clamp"])
            firefly_clamp = [settingsDict[@"firefly_clamp"] floatValue];
        if (settingsDict[@"world_hdri_path"]) {
            hdri_path = [settingsDict[@"world_hdri_path"] UTF8String];
            has_hdri = !hdri_path.empty();
        }
        // show_background defaults to true if key missing
        if (settingsDict[@"show_background"])
            outData._showBackground = [settingsDict[@"show_background"] intValue] != 0;
            
        // Global Volume (Fog)
        if (settingsDict[@"vol_density"])
            outData._volDensity = [settingsDict[@"vol_density"] floatValue];
        if (settingsDict[@"vol_color"]) {
            NSArray* vc = settingsDict[@"vol_color"];
            outData._volColor = simd_make_float3([vc[0] floatValue], [vc[1] floatValue], [vc[2] floatValue]);
        }
        if (settingsDict[@"vol_anisotropy"])
            outData._volAnisotropy = [settingsDict[@"vol_anisotropy"] floatValue];
        if (settingsDict[@"vol_falloff"])
            outData._volFalloff = [settingsDict[@"vol_falloff"] floatValue];
    }

    
    // Store DoF + env params to pass through to uniforms via SceneData (temporarily via static)
    // We use a simple singleton approach via static fields on SceneData
    outData._dofFocalDistance  = dof_focal_distance;
    outData._dofApertureRadius = dof_aperture_radius;
    outData._envStrength       = env_strength;
    outData._fireflyClamp      = firefly_clamp;
    outData._hasHDRI           = has_hdri;
    outData._hdriPath          = hdri_path;

    NSArray* lights = json[@"lights"];
    _lightCount = lights != nil ? (int)lights.count : 0;
    
    std::vector<LightData> lightData(MAX(1, _lightCount));
    for (int i = 0; i < _lightCount; i++) {
        NSDictionary* l = lights[i];
        NSArray* pos = l[@"position"];
        NSArray* col = l[@"color"];
        lightData[i].position = simd_make_float3([pos[0] floatValue], [pos[1] floatValue], [pos[2] floatValue]);
        lightData[i].color    = simd_make_float3([col[0] floatValue], [col[1] floatValue], [col[2] floatValue]);
        lightData[i].power    = [l[@"power"] floatValue];
        // Type
        NSString* typeStr = l[@"type"];
        if      ([typeStr isEqualToString:@"SUN"])       lightData[i].type = 1;
        else if ([typeStr isEqualToString:@"SPOT"])      lightData[i].type = 2;
        else if ([typeStr isEqualToString:@"AREA_RECT"]) lightData[i].type = 3;
        else if ([typeStr isEqualToString:@"AREA_DISK"]) lightData[i].type = 4;
        else                                             lightData[i].type = 0; // POINT
        // Direction (sun/spot)
        if (l[@"direction"]) {
            NSArray* d = l[@"direction"];
            lightData[i].direction = simd_make_float3([d[0] floatValue], [d[1] floatValue], [d[2] floatValue]);
        }
        // Spot params
        lightData[i].spotAngle = l[@"spot_angle"] ? [l[@"spot_angle"] floatValue] : 0.785398f; // 45 deg
        lightData[i].spotBlend = l[@"spot_blend"] ? [l[@"spot_blend"] floatValue] : 0.15f;
        // Area params
        if (l[@"u_axis"]) {
            NSArray* ua = l[@"u_axis"]; NSArray* va = l[@"v_axis"];
            lightData[i].u_axis = simd_make_float3([ua[0] floatValue], [ua[1] floatValue], [ua[2] floatValue]);
            lightData[i].v_axis = simd_make_float3([va[0] floatValue], [va[1] floatValue], [va[2] floatValue]);
        } else {
            lightData[i].u_axis = simd_make_float3(1, 0, 0);
            lightData[i].v_axis = simd_make_float3(0, 1, 0);
        }
        lightData[i].width  = l[@"width"]  ? [l[@"width"]  floatValue] : 1.0f;
        lightData[i].height = l[@"height"] ? [l[@"height"] floatValue] : 1.0f;
    }
    _lightsBuffer = [_device newBufferWithBytes:lightData.data() length:sizeof(LightData) * MAX(1, _lightCount) options:MTLResourceStorageModeShared];

    
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:_device];
    
    // --- Load JIT Material Textures FIRST ---
    // This ensures their indices (0, 1, 2...) match the indices generated by the Python node compiler
    NSArray* jitTextures = json[@"material_textures"];
    if (jitTextures && [jitTextures count] > 0) {
        for (NSString* path in jitTextures) {
            if (_sceneTextures.size() >= 30) {
                std::cerr << "--- METAL WARNING: Texture limit (30) reached. Skipping: " << [path lastPathComponent].UTF8String << std::endl;
                break;
            }
            NSURL* url = [NSURL fileURLWithPath:path];
            NSError* err = nil;
            id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url options:@{MTKTextureLoaderOptionSRGB: @NO} error:&err];
            if (tex) {
                _sceneTextures.push_back(tex);
                std::cout << "--- METAL INFO: Successfully loaded material texture: " << [path lastPathComponent].UTF8String << std::endl;
            } else {
                std::cerr << "--- METAL ERROR: Failed to load material texture: " << [[err localizedDescription] UTF8String] << " at " << [path UTF8String] << std::endl;
                // PUSH FALLBACK to keep JIT indices in sync!
                MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
                id<MTLTexture> fallback = [_device newTextureWithDescriptor:td];
                simd_float4 magenta = {1.0, 0.0, 1.0, 1.0};
                [fallback replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&magenta bytesPerRow:16];
                _sceneTextures.push_back(fallback);
            }
        }
    }

    NSDictionary* materials = json[@"materials"];
    int matCount = MAX(1, (int)mtlMap.size());
    std::vector<MaterialData> matData(matCount);
    for (const auto& pair : mtlMap) {
        NSDictionary* m = materials != nil ? materials[[NSString stringWithUTF8String:pair.first.c_str()]] : nil;
        if (m) {
            NSArray* alb = m[@"albedo"];
            matData[pair.second].albedo = simd_make_float3([alb[0] floatValue], [alb[1] floatValue], [alb[2] floatValue]);
            matData[pair.second].emission = [m[@"emission"] floatValue];
            matData[pair.second].metallic = m[@"metallic"] != nil ? [m[@"metallic"] floatValue] : 0.0f;
            matData[pair.second].roughness = m[@"roughness"] != nil ? [m[@"roughness"] floatValue] : 0.5f;
            matData[pair.second].transmission = m[@"transmission"] != nil ? [m[@"transmission"] floatValue] : 0.0f;
            matData[pair.second].ior = m[@"ior"] != nil ? [m[@"ior"] floatValue] : 1.45f;
            
            // Volumetrics
            matData[pair.second].isVolumetric = m[@"isVolumetric"] != nil ? [m[@"isVolumetric"] unsignedIntValue] : 0;
            matData[pair.second].volDensity = m[@"volDensity"] != nil ? [m[@"volDensity"] floatValue] : 0.0f;
            if (m[@"volColor"]) {
                NSArray* vc = m[@"volColor"];
                matData[pair.second].volColor = simd_make_float3([vc[0] floatValue], [vc[1] floatValue], [vc[2] floatValue]);
            } else {
                matData[pair.second].volColor = simd_make_float3(1, 1, 1);
            }
            matData[pair.second].baseColorIndex = -1;
            matData[pair.second].normalMapIndex = -1;
            
            NSString* texStr = m[@"texture"];
            if (texStr && ![texStr isEqual:[NSNull null]] && [texStr length] > 0) {
                NSURL* url = [NSURL fileURLWithPath:texStr];
                id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url options:@{MTKTextureLoaderOptionSRGB: @NO} error:nil];
                if (tex) { matData[pair.second].baseColorIndex = _sceneTextures.size(); _sceneTextures.push_back(tex); }
            }
            
            NSString* nTexStr = m[@"normalMap"];
            if (nTexStr && ![nTexStr isEqual:[NSNull null]] && [nTexStr length] > 0) {
                NSURL* url = [NSURL fileURLWithPath:nTexStr];
                id<MTLTexture> tex = [loader newTextureWithContentsOfURL:url options:@{MTKTextureLoaderOptionSRGB: @NO} error:nil];
                if (tex) { matData[pair.second].normalMapIndex = _sceneTextures.size(); _sceneTextures.push_back(tex); }
            }
        } else {
            matData[pair.second].albedo = simd_make_float3(0.8, 0.8, 0.8);
            matData[pair.second].emission = 0.0;
            matData[pair.second].metallic = 0.0;
            matData[pair.second].roughness = 0.5;
            matData[pair.second].transmission = 0.0;
            matData[pair.second].ior = 1.45;
            matData[pair.second].baseColorIndex = -1;
            matData[pair.second].normalMapIndex = -1;
        }
    }

    _materialsBuffer = [_device newBufferWithBytes:matData.data() length:sizeof(MaterialData) * matCount options:MTLResourceStorageModeShared];

    
    return true;
}

id<MTLAccelerationStructure> Renderer::buildAccelerationStructure(const SceneData& data) {
    id<MTLBuffer> vertexBuffer = [_device newBufferWithBytes:data.vertices length:data.vertexCount * sizeof(VertexData) options:MTLResourceStorageModeShared];
    id<MTLBuffer> indexBuffer = [_device newBufferWithBytes:data.indices length:data.indexCount * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    
    MTLAccelerationStructureTriangleGeometryDescriptor* geomDesc = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    geomDesc.vertexBuffer = vertexBuffer;
    geomDesc.vertexStride = sizeof(VertexData);
    geomDesc.indexBuffer = indexBuffer;
    geomDesc.indexType = MTLIndexTypeUInt32;
    geomDesc.triangleCount = data.indexCount / 3;
    geomDesc.opaque = YES;
    
    MTLPrimitiveAccelerationStructureDescriptor* accelDesc = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    accelDesc.geometryDescriptors = @[geomDesc];
    
    MTLAccelerationStructureSizes sizes = [_device accelerationStructureSizesWithDescriptor:accelDesc];
    id<MTLAccelerationStructure> outAccel = [_device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
    id<MTLBuffer> scratchBuffer = [_device newBufferWithLength:sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLAccelerationStructureCommandEncoder> encoder = [commandBuffer accelerationStructureCommandEncoder];
    [encoder buildAccelerationStructure:outAccel descriptor:accelDesc scratchBuffer:scratchBuffer scratchBufferOffset:0];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    return outAccel;
}

bool Renderer::saveImage(const std::string& path, uint8_t* pixels, int width, int height) {
    if (path.empty()) {
        std::cerr << "Error: path is empty in saveImage!" << std::endl;
        return false;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast);
    if (!context) {
        std::cerr << "Error: CGBitmapContextCreate failed!" << std::endl;
        CGColorSpaceRelease(colorSpace);
        return false;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    if (!nsPath) {
        std::cerr << "Error: stringWithUTF8String returned nil for path: " << path << std::endl;
        CGImageRelease(image);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        return false;
    }
    NSURL* url = [NSURL fileURLWithPath:nsPath];
    if (!url) {
        std::cerr << "Error: fileURLWithPath returned nil!" << std::endl;
        CGImageRelease(image);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        return false;
    }
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((CFURLRef)url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    bool success = CGImageDestinationFinalize(dest);
    
    CFRelease(dest);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    return success;
}

bool Renderer::handleScene(const std::string& objPath, const std::string& jsonPath, const std::string& outPath, int width, int height, const std::string& generatedShaderPath) {
    std::cout << "handleScene START. objPath: [" << objPath << "] jsonPath: [" << jsonPath << "] outPath: [" << outPath << "]" << std::endl;
    // JIT: Load Shaders and compile runtime pipelines
    NSError* error = nil;
    NSString *shaderPath = @"Shaders.metal";
    NSString *shaderSource = [NSString stringWithContentsOfFile:shaderPath encoding:NSUTF8StringEncoding error:&error];
    if (!shaderSource) {
        std::cerr << "Failed to read Shaders.metal" << std::endl;
        return false;
    }
    
    NSString* generatedSource = @"\ninline float3 evaluate_material_jit(uint matIdx, float3 P, float2 UV, float3 default_albedo, sampler textureSampler, array<texture2d<float>, 30> texArray) { return default_albedo; }\n";
    if (!generatedShaderPath.empty()) {
        NSString *genPath = [NSString stringWithUTF8String:generatedShaderPath.c_str()];
        NSString *genCont = [NSString stringWithContentsOfFile:genPath encoding:NSUTF8StringEncoding error:nil];
        if (genCont) generatedSource = genCont;
    }
    
    NSString *metalPreamble = @"#include <metal_stdlib>\nusing namespace metal;\n\n";
    NSString *fullSource = [NSString stringWithFormat:@"%@%@\n%@", metalPreamble, generatedSource, shaderSource];
    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> defaultLibrary = [_device newLibraryWithSource:fullSource options:options error:&error];
    
    if (!defaultLibrary) {
        std::cerr << "JIT Compilation Failed:\n" << [[error localizedDescription] UTF8String] << std::endl;
        return false;
    }
    
    _raytracingPipeline = [_device newComputePipelineStateWithFunction:[defaultLibrary newFunctionWithName:@"raytrace_kernel"] error:&error];
    _photonEmissionPipeline = [_device newComputePipelineStateWithFunction:[defaultLibrary newFunctionWithName:@"emit_photons_kernel"] error:&error];
    _hashGridClearPipeline = [_device newComputePipelineStateWithFunction:[defaultLibrary newFunctionWithName:@"hash_grid_clear_kernel"] error:&error];
    
    if (!_raytracingPipeline || !_photonEmissionPipeline || !_hashGridClearPipeline) {
        std::cerr << "Failed to create runtime pipeline states: " << [[error localizedDescription] UTF8String] << std::endl;
        return false;
    }

    std::unordered_map<std::string, uint32_t> mtlMap;
    SceneData sceneData;
    sceneData.samples = 1;
    sceneData.bounces = 1;
    sceneData.cameraPos = {0, 0, 5};
    sceneData.cameraTarget = {0, 0, 0};
    // Camera
    NSDictionary* jsonObj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:jsonPath.c_str()]] options:0 error:nil];
    NSDictionary* camera = jsonObj[@"camera"];
    if (camera && [camera count] > 0) {
        NSArray* pos = camera[@"position"];
        NSArray* tgt = camera[@"target"];
        NSArray* up  = camera[@"up"];
        if (pos && tgt && up) {
            sceneData.cameraPos    = simd_make_float3([pos[0] floatValue], [pos[1] floatValue], [pos[2] floatValue]);
            sceneData.cameraTarget = simd_make_float3([tgt[0] floatValue], [tgt[1] floatValue], [tgt[2] floatValue]);
            sceneData.cameraUp     = simd_make_float3([up[0]  floatValue], [up[1]  floatValue], [up[2]  floatValue]);
            sceneData.fov          = [camera[@"fov"] floatValue];
        }
    }

    
    if (!loadSimpleObj(objPath, sceneData, mtlMap)) {
        std::cerr << "Failed to load OBJ: " << objPath << std::endl;
        return false;
    }
    if (!loadSceneData(jsonPath, sceneData, mtlMap)) {
        std::cerr << "Warning: Failed to load scene data JSON: " << jsonPath << std::endl;
    }
    
    sceneData.width = width;
    sceneData.height = height;
    
    id<MTLAccelerationStructure> accel = nullptr;
    if (sceneData.vertexCount > 0 && sceneData.indexCount > 0) {
        accel = buildAccelerationStructure(sceneData);
    }
    
    // Create material indices buffer
    size_t matIdxAlloc = std::max((size_t)1, sceneData.indexCount / 3);
    id<MTLBuffer> matIndexBuffer = [_device newBufferWithBytes:sceneData.materialIndices length:matIdxAlloc * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    
    // Create output texture
    MTLTextureDescriptor* texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    texDesc.storageMode = MTLStorageModeShared; // Apple Silicon pure Unified Memory optimization
    id<MTLTexture> outTexture = [_device newTextureWithDescriptor:texDesc];
    
    Uniforms uniforms;
    uniforms.cameraPos = sceneData.cameraPos;
    uniforms.cameraTarget = sceneData.cameraTarget;
    uniforms.cameraUp = sceneData.cameraUp;
    uniforms.fov = sceneData.fov;
    uniforms.width = width;
    uniforms.height = height;
    uniforms.samples = sceneData.samples;
    uniforms.bounces = sceneData.bounces;
    uniforms.lightCount = _lightCount;
    // Photon Grid setup (40x40x40 = 64k cells covering a 20x20x20 volume)
    uniforms.gridMinX = -10.0f;
    uniforms.gridMinY = -10.0f;
    uniforms.gridMinZ = -10.0f;
    uniforms.gridCellSize = 0.5f;
    uniforms.focalDistance  = sceneData._dofFocalDistance;
    uniforms.apertureRadius = sceneData._dofApertureRadius;
    uniforms.envStrength    = sceneData._envStrength;
    uniforms.hasHDRI        = sceneData._hasHDRI ? 1u : 0u;
    uniforms.fireflyClamp   = sceneData._fireflyClamp;
    uniforms.showBackground = sceneData._showBackground ? 1u : 0u;
    uniforms.volDensity     = sceneData._volDensity;
    uniforms.volColor       = sceneData._volColor;
    uniforms.volAnisotropy  = sceneData._volAnisotropy;
    uniforms.volFalloff     = sceneData._volFalloff;

    uniforms.gridResolution = 40;
    uniforms.gridTotalCells = 64000;
    uniforms.causticRadius = 0.5f;
    uniforms.maxPhotons = 1000000;
    
    _photonBuffer = [_device newBufferWithLength:48 * uniforms.maxPhotons options:MTLResourceStorageModePrivate]; // 48 bytes per PhotonNode approx
    _hashGridBuffer = [_device newBufferWithLength:4 * uniforms.gridTotalCells options:MTLResourceStorageModePrivate];
    uint32_t zeroCounter = 0;
    _globalAtomicBuffer = [_device newBufferWithBytes:&zeroCounter length:4 options:MTLResourceStorageModeShared];
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    
    // Pass 1: Clear Hash Grid
    id<MTLComputeCommandEncoder> clearEncoder = [commandBuffer computeCommandEncoder];
    [clearEncoder setComputePipelineState:_hashGridClearPipeline];
    [clearEncoder setBuffer:_hashGridBuffer offset:0 atIndex:0];
    [clearEncoder setBytes:&uniforms length:sizeof(Uniforms) atIndex:1];
    [clearEncoder dispatchThreadgroups:MTLSizeMake((uniforms.gridTotalCells + 63) / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [clearEncoder endEncoding];
    
    // Pass 2: Emit Photons
    id<MTLComputeCommandEncoder> photonEncoder = [commandBuffer computeCommandEncoder];
    [photonEncoder setComputePipelineState:_photonEmissionPipeline];
    [photonEncoder setBuffer:_photonBuffer offset:0 atIndex:0];
    [photonEncoder setBuffer:_globalAtomicBuffer offset:0 atIndex:1];
    [photonEncoder setBuffer:_hashGridBuffer offset:0 atIndex:2];
    if (accel) [photonEncoder setAccelerationStructure:accel atBufferIndex:3];
    [photonEncoder setBytes:&uniforms length:sizeof(Uniforms) atIndex:4];
    [photonEncoder setBuffer:_lightsBuffer offset:0 atIndex:5];
    [photonEncoder setBuffer:_materialsBuffer offset:0 atIndex:6];
    [photonEncoder setBuffer:matIndexBuffer offset:0 atIndex:7];
    [photonEncoder setBuffer:_vertexBuffer offset:0 atIndex:8];
    [photonEncoder setBuffer:_indexBuffer offset:0 atIndex:9];
    [photonEncoder dispatchThreadgroups:MTLSizeMake((uniforms.maxPhotons + 63) / 64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [photonEncoder endEncoding];
    
    // Load HDRI environment texture if specified
    id<MTLTexture> envTexture = nil;
    bool load_success = false;
    
    if (sceneData._hasHDRI && !sceneData._hdriPath.empty()) {
        NSString* hdriNS = [NSString stringWithUTF8String:sceneData._hdriPath.c_str()];
        NSURL* hdriURL = [NSURL fileURLWithPath:hdriNS];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:hdriNS]) {
            std::cerr << "--- METAL ERROR: HDRI file not found at: " << [hdriNS UTF8String] << std::endl;
        } else {
            MTKTextureLoader* envLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
            NSDictionary* envOpts = @{
                MTKTextureLoaderOptionSRGB: @NO,
                MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead)
            };
            NSError* envErr = nil;
            envTexture = [envLoader newTextureWithContentsOfURL:hdriURL options:envOpts error:&envErr];
            
            if (envTexture) {
                load_success = true;
                std::cout << "--- METAL INFO: Successfully loaded environment: " << [hdriNS lastPathComponent].UTF8String << " (" << envTexture.width << "x" << envTexture.height << ")" << std::endl;
            } else {
                std::cerr << "--- METAL ERROR: Fail to load picture format: " << [[envErr localizedDescription] UTF8String] << std::endl;
                std::cerr << "--- TIP: macOS prefers .exr or .png/.jpg for HDRIs. Standard .hdr files sometimes fail." << std::endl;
            }
        }
    }
    
    // Fallback if failed/none
    if (!envTexture) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        envTexture = [_device newTextureWithDescriptor:td];
        simd_float4 fallbackCol = {0.5f, 0.5f, 0.5f, 1.0f};
        [envTexture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&fallbackCol bytesPerRow:16];
    }
    
    // Set shader uniforms based on REAL loading state
    uniforms.hasHDRI = load_success ? 1u : 0u;

    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:_raytracingPipeline];
    [encoder setTexture:outTexture atIndex:0];
    
    if (_sceneTextures.size() > 0) {
        std::vector<id<MTLTexture>> texArray(_sceneTextures);
        [encoder setTextures:texArray.data() withRange:NSMakeRange(1, texArray.size())];
    }
    // Bind environment texture at slot 31
    [encoder setTexture:envTexture atIndex:31];

    if (accel) [encoder setAccelerationStructure:accel atBufferIndex:0];
    [encoder setBytes:&uniforms length:sizeof(Uniforms) atIndex:1];
    [encoder setBuffer:_lightsBuffer offset:0 atIndex:2];
    [encoder setBuffer:_materialsBuffer offset:0 atIndex:3];
    [encoder setBuffer:matIndexBuffer offset:0 atIndex:4];
    [encoder setBuffer:_vertexBuffer offset:0 atIndex:5];
    [encoder setBuffer:_indexBuffer offset:0 atIndex:6];
    [encoder setBuffer:_photonBuffer offset:0 atIndex:7];
    [encoder setBuffer:_hashGridBuffer offset:0 atIndex:8];
    
    [encoder dispatchThreadgroups:MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder endEncoding];
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    // Readback pixels
    size_t rowBytes = width * 4;
    std::vector<uint8_t> pixels(rowBytes * height);
    [outTexture getBytes:pixels.data() bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    
    bool saved = saveImage(outPath, pixels.data(), width, height);
    
    delete[] sceneData.vertices;
    delete[] sceneData.indices;
    delete[] sceneData.materialIndices;
    
    return saved;
}
