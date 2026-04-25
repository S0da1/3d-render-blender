#pragma once

#import <Metal/Metal.h>
#import <simd/simd.h>
#include <unordered_map>
#include <string>
#include <vector>

struct VertexData {
    simd_float3 position;
    simd_float2 uv;
    simd_float3 normal;
};

struct SceneData {
    VertexData* vertices;
    size_t vertexCount;
    uint32_t* indices;
    uint32_t* materialIndices; // 1 per triangle
    size_t indexCount;
    
    // Camera
    simd_float3 cameraPos;
    simd_float3 cameraTarget;
    simd_float3 cameraUp;
    float fov;
    int samples;
    int bounces;
    
    int width;
    int height;
    
    // Depth of Field
    float _dofFocalDistance  = 10.0f;
    float _dofApertureRadius = 0.0f;
    // Environment
    float _envStrength  = 1.0f;
    bool  _hasHDRI      = false;
    std::string _hdriPath;
    // Firefly clamping
    float _fireflyClamp = 10.0f;
    // Background
    bool _showBackground = true;
    
    // Global Volume (Fog)
    float _volDensity = 0.0f;
    simd_float3 _volColor = {1.0f, 1.0f, 1.0f};
    float _volAnisotropy = 0.0f;
    float _volFalloff = 0.2f;
};


class Renderer {
public:
    Renderer();
    ~Renderer();

    bool handleScene(const std::string& objPath, const std::string& jsonPath, const std::string& outPath, int width, int height, const std::string& generatedShaderPath = "");

private:
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLComputePipelineState> _raytracingPipeline;
    id<MTLComputePipelineState> _photonEmissionPipeline;
    id<MTLComputePipelineState> _hashGridClearPipeline;
    id<MTLComputePipelineState> _hashGridBuildPipeline;
    std::vector<id<MTLTexture>> _sceneTextures;
    
    // Parsed dynamically from JSON
    id<MTLBuffer> _lightsBuffer;
    id<MTLBuffer> _materialsBuffer;
    id<MTLBuffer> _vertexBuffer;
    id<MTLBuffer> _indexBuffer;
    id<MTLBuffer> _photonBuffer;
    id<MTLBuffer> _hashGridBuffer;
    id<MTLBuffer> _globalAtomicBuffer;
    int _lightCount = 0;
    
    bool loadSimpleObj(const std::string& filepath, SceneData& outData, std::unordered_map<std::string, uint32_t>& mtlMap);
    bool loadSceneData(const std::string& jsonPath, SceneData& outData, const std::unordered_map<std::string, uint32_t>& mtlMap);
    id<MTLAccelerationStructure> buildAccelerationStructure(const SceneData& data);
    bool saveImage(const std::string& path, uint8_t* pixels, int width, int height);
};
