#import "Renderer.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MetalKit/MetalKit.h>
#include <fstream>
#include <sstream>
#include <vector>
#include <iostream>

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
};

struct LightData {
    simd_float3 position;
    simd_float3 color;
    float power;
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
};

Renderer::Renderer() {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        std::cerr << "Metal is not supported on this device" << std::endl;
        exit(1);
    }
    _commandQueue = [_device newCommandQueue];
    
    // Load shaders at runtime from source file
    NSError* error = nil;
    NSString *shaderPath = @"Shaders.metal";
    NSString *shaderSource = [NSString stringWithContentsOfFile:shaderPath encoding:NSUTF8StringEncoding error:&error];
    if (!shaderSource) {
        std::cerr << "Failed to read Shaders.metal: " << [[error localizedDescription] UTF8String] << std::endl;
        exit(1);
    }
    
    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> defaultLibrary = [_device newLibraryWithSource:shaderSource options:options error:&error];
    if (!defaultLibrary) {
        std::cerr << "Failed to compile Shaders.metal at runtime: " << [[error localizedDescription] UTF8String] << std::endl;
        exit(1);
    }
    
    id<MTLFunction> raytraceFunction = [defaultLibrary newFunctionWithName:@"raytrace_kernel"];
    _raytracingPipeline = [_device newComputePipelineStateWithFunction:raytraceFunction error:&error];
    if (!_raytracingPipeline) {
        std::cerr << "Failed to create pipeline state: " << [[error localizedDescription] UTF8String] << std::endl;
        exit(1);
    }
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
        if (line.empty()) continue;
        std::istringstream ss(line);
        std::string type;
        ss >> type;
        
        if (type == "usemtl") {
            ss >> currentMtl;
            if (mtlMap.find(currentMtl) == mtlMap.end()) {
                mtlMap[currentMtl] = mtlMap.size();
            }
        }
        else if (type == "v") {
            float x, y, z; ss >> x >> y >> z;
            temp_v.push_back(simd_make_float3(x, y, z));
        } else if (type == "vt") {
            float u, v; ss >> u >> v;
            temp_vt.push_back(simd_make_float2(u, v));
        } else if (type == "vn") {
            float nx, ny, nz; ss >> nx >> ny >> nz;
            temp_vn.push_back(simd_make_float3(nx, ny, nz));
        } else if (type == "f") {
            std::string v1, v2, v3;
            ss >> v1 >> v2 >> v3;
            auto processVertex = [&](const std::string& vertexStr) -> uint32_t {
                if (uniqueVertices.count(vertexStr) == 0) {
                    uniqueVertices[vertexStr] = out_vertices.size();
                    
                    std::istringstream vss(vertexStr);
                    std::string segment;
                    int v_idx = 0, vt_idx = 0, vn_idx = 0;
                    
                    if (std::getline(vss, segment, '/')) v_idx = !segment.empty() ? std::stoi(segment) : 0;
                    if (std::getline(vss, segment, '/')) vt_idx = !segment.empty() ? std::stoi(segment) : 0;
                    if (std::getline(vss, segment, '/')) vn_idx = !segment.empty() ? std::stoi(segment) : 0;
                    
                    VertexData vd;
                    vd.position = (v_idx > 0 && v_idx <= temp_v.size()) ? temp_v[v_idx - 1] : simd_make_float3(0,0,0);
                    vd.uv = (vt_idx > 0 && vt_idx <= temp_vt.size()) ? temp_vt[vt_idx - 1] : simd_make_float2(0,0);
                    vd.normal = (vn_idx > 0 && vn_idx <= temp_vn.size()) ? temp_vn[vn_idx - 1] : simd_make_float3(0,1,0);
                    out_vertices.push_back(vd);
                }
                return uniqueVertices[vertexStr];
            };
            indices.push_back(processVertex(v1));
            indices.push_back(processVertex(v2));
            indices.push_back(processVertex(v3));
            matIndices.push_back(mtlMap[currentMtl]);
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
    
    NSDictionary* settings = json[@"settings"];
    outData.samples = [settings[@"samples"] intValue];
    outData.bounces = [settings[@"bounces"] intValue];
    
    NSDictionary* camera = json[@"camera"];
    if (camera && [camera count] > 0) {
        NSArray* pos = camera[@"position"];
        NSArray* tgt = camera[@"target"];
        NSArray* up = camera[@"up"];
        if (pos && tgt && up) {
            outData.cameraPos = simd_make_float3([pos[0] floatValue], [pos[1] floatValue], [pos[2] floatValue]);
            outData.cameraTarget = simd_make_float3([tgt[0] floatValue], [tgt[1] floatValue], [tgt[2] floatValue]);
            outData.cameraUp = simd_make_float3([up[0] floatValue], [up[1] floatValue], [up[2] floatValue]);
            outData.fov = [camera[@"fov"] floatValue];
        }
    }
    
    NSArray* lights = json[@"lights"];
    _lightCount = lights != nil ? lights.count : 0;
    
    std::vector<LightData> lightData(MAX(1, _lightCount));
    for (int i = 0; i < _lightCount; i++) {
        NSDictionary* l = lights[i];
        NSArray* pos = l[@"position"];
        NSArray* col = l[@"color"];
        lightData[i].position = simd_make_float3([pos[0] floatValue], [pos[1] floatValue], [pos[2] floatValue]);
        lightData[i].color = simd_make_float3([col[0] floatValue], [col[1] floatValue], [col[2] floatValue]);
        lightData[i].power = [l[@"power"] floatValue];
    }
    _lightsBuffer = [_device newBufferWithBytes:lightData.data() length:sizeof(LightData) * MAX(1, _lightCount) options:MTLResourceStorageModeShared];
    
    MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:_device];
    
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
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((CFURLRef)url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    bool success = CGImageDestinationFinalize(dest);
    
    CFRelease(dest);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    return success;
}

bool Renderer::handleScene(const std::string& objPath, const std::string& jsonPath, const std::string& outPath, int width, int height) {
    std::unordered_map<std::string, uint32_t> mtlMap;
    SceneData sceneData;
    sceneData.samples = 1;
    sceneData.bounces = 1;
    sceneData.cameraPos = {0, 0, 5};
    sceneData.cameraTarget = {0, 0, 0};
    sceneData.cameraUp = {0, 1, 0};
    sceneData.fov = 60.0f;
    
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
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    
    [encoder setComputePipelineState:_raytracingPipeline];
    [encoder setTexture:outTexture atIndex:0];
    
    if (_sceneTextures.size() > 0) {
        std::vector<id<MTLTexture>> texArray(_sceneTextures);
        [encoder setTextures:texArray.data() withRange:NSMakeRange(1, texArray.size())];
    }
    
    if (accel) {
        [encoder setAccelerationStructure:accel atBufferIndex:0];
    }
    [encoder setBytes:&uniforms length:sizeof(Uniforms) atIndex:1];
    [encoder setBuffer:_lightsBuffer offset:0 atIndex:2];
    [encoder setBuffer:_materialsBuffer offset:0 atIndex:3];
    [encoder setBuffer:matIndexBuffer offset:0 atIndex:4];
    [encoder setBuffer:_vertexBuffer offset:0 atIndex:5];
    [encoder setBuffer:_indexBuffer offset:0 atIndex:6];
    
    MTLSize threadsPerThreadgroup = MTLSizeMake(8, 8, 1);
    MTLSize threadgroups = MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1);
    [encoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerThreadgroup];
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
