#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace metal::raytracing;

struct Uniforms {
    float3 cameraPos;
    float3 cameraTarget;
    float3 cameraUp;
    float fov;
    uint width;
    uint height;
    uint samples;
    uint bounces;
    uint lightCount;
};

struct LightData {
    float3 position;
    float3 color;
    float power;
};

struct MaterialData {
    float3 albedo;
    float emission;
    float metallic;
    float roughness;
    float transmission;
    float ior;
    int baseColorIndex;
    int normalMapIndex;
};

struct VertexData {
    float3 position;
    float2 uv;
    float3 normal;
};

float random(thread uint2& state) {
    state.x ^= state.x << 13;
    state.x ^= state.x >> 17;
    state.x ^= state.x << 5;
    state.y ^= state.y << 13;
    state.y ^= state.y >> 17;
    state.y ^= state.y << 5;
    return float(state.x + state.y) / 4294967296.0f;
}

float3 sample_cosine_hemisphere(thread uint2& state, float3 normal) {
    float u1 = random(state);
    float u2 = random(state);
    float r = sqrt(u1);
    float theta = 2.0 * 3.14159265 * u2;
    float3 dir = float3(r * cos(theta), r * sin(theta), sqrt(1.0 - u1));
    
    float3 up = abs(normal.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    return normalize(tangent * dir.x + bitangent * dir.y + normal * dir.z);
}

float3 sample_ggx(thread uint2& state, float3 normal, float roughness) {
    float a = max(0.001f, roughness * roughness);
    float u1 = random(state);
    float u2 = random(state);
    
    float phi = 2.0 * 3.14159265 * u1;
    float cosTheta = sqrt((1.0 - u2) / (1.0 + (a*a - 1.0) * u2));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    
    float3 H = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
    
    float3 up = abs(normal.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    return normalize(tangent * H.x + bitangent * H.y + normal * H.z);
}

float3 schlick_fresnel(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Fresnel for dielectrics (glass)
float fresnel_dielectric(float cosThetaI, float ior) {
    float etaI = 1.0;
    float etaT = ior;
    if (cosThetaI < 0.0) {
        etaI = ior;
        etaT = 1.0;
        cosThetaI = -cosThetaI;
    }
    float sinThetaT2 = (etaI * etaI) / (etaT * etaT) * (1.0 - cosThetaI * cosThetaI);
    if (sinThetaT2 >= 1.0) return 1.0; // Total Internal Reflection
    float cosThetaT = sqrt(1.0 - sinThetaT2);
    
    float r1 = (etaT * cosThetaI - etaI * cosThetaT) / (etaT * cosThetaI + etaI * cosThetaT);
    float r2 = (etaI * cosThetaI - etaT * cosThetaT) / (etaI * cosThetaI + etaT * cosThetaT);
    return (r1 * r1 + r2 * r2) * 0.5;
}

float D_GGX(float NdotH, float roughness) {
    float a = max(0.001f, roughness * roughness);
    float a2 = a * a;
    float NdotH2 = NdotH * NdotH;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = 3.14159265 * denom * denom;
    return a2 / max(0.0000001f, denom);
}

float G_Smith(float NdotV, float NdotL, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    float ggx1 = NdotV / (NdotV * (1.0 - k) + k);
    float ggx2 = NdotL / (NdotL * (1.0 - k) + k);
    return ggx1 * ggx2;
}

kernel void raytrace_kernel(
    texture2d<float, access::write> outTexture [[texture(0)]],
    array<texture2d<float>, 30> sceneTextures [[texture(1)]],
    primitive_acceleration_structure accel [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    constant LightData* lights [[buffer(2)]],
    constant MaterialData* materials [[buffer(3)]],
    constant uint* materialIndices [[buffer(4)]],
    constant VertexData* vertices [[buffer(5)]],
    constant uint* indices [[buffer(6)]],
    uint2 tid [[thread_position_in_grid]]
) {
    if (tid.x >= uniforms.width || tid.y >= uniforms.height) return;

    uint2 state = uint2(tid.x * 1973 + tid.y * 9277, tid.y * 26699 + tid.x * 12345);
    
    float3 accumulatedColor = float3(0.0);
    uint SAMPLES = uniforms.samples;

    for (uint s = 0; s < SAMPLES; s++) {
        float rx = random(state) - 0.5;
        float ry = random(state) - 0.5;
        float u = (float(tid.x) + rx) / uniforms.width * 2.0 - 1.0;
        float v = 1.0 - (float(tid.y) + ry) / uniforms.height * 2.0;
        
        float3 forward = normalize(uniforms.cameraTarget - uniforms.cameraPos);
        float3 right = normalize(cross(forward, uniforms.cameraUp));
        float3 up_dir = cross(right, forward);
        
        float aspect = float(uniforms.width) / float(uniforms.height);
        float hScale = tan(uniforms.fov * 0.5);
        float vScale = hScale / aspect;
        
        float3 rayDir = normalize(forward + right * u * hScale + up_dir * v * vScale);
        
        float3 throughput = float3(1.0);
        float3 radiance = float3(0.0);
        
        ray r;
        r.origin = uniforms.cameraPos;
        r.direction = rayDir;
        r.min_distance = 0.001;
        r.max_distance = 1000.0;
        
        for (uint b = 0; b < uniforms.bounces; b++) {
            intersector<triangle_data> intersec;
            intersec.accept_any_intersection(false);
            auto intersection = intersec.intersect(r, accel);
            
            if (intersection.type == intersection_type::none) {
                // Bright white environment light for aggressive GI/AO
                radiance += throughput * float3(0.8, 0.8, 0.85);
                break;
            }
            
            uint prim_id = intersection.primitive_id;
            uint mat_id = materialIndices[prim_id];
            MaterialData mat = materials[mat_id];
            
            uint i0 = indices[prim_id * 3 + 0];
            uint i1 = indices[prim_id * 3 + 1];
            uint i2 = indices[prim_id * 3 + 2];
            
            VertexData v0 = vertices[i0];
            VertexData v1 = vertices[i1];
            VertexData v2 = vertices[i2];
            
            float2 baryCoords = intersection.triangle_barycentric_coord;
            float b0 = 1.0 - baryCoords.x - baryCoords.y;
            float b1 = baryCoords.x;
            float b2 = baryCoords.y;
            
            float3 smoothNormal = normalize(v0.normal * b0 + v1.normal * b1 + v2.normal * b2);
            float2 hitUV = v0.uv * b0 + v1.uv * b1 + v2.uv * b2;
            
            constexpr sampler texSampler(address::repeat, filter::linear);
            
            float3 matAlbedo = mat.albedo;
            if (mat.baseColorIndex >= 0) {
                matAlbedo = sceneTextures[mat.baseColorIndex].sample(texSampler, hitUV).rgb;
            }
            
            float3 normal = smoothNormal;
            if (mat.normalMapIndex >= 0) {
                float3 edge1 = v1.position - v0.position;
                float3 edge2 = v2.position - v0.position;
                float2 deltaUV1 = v1.uv - v0.uv;
                float2 deltaUV2 = v2.uv - v0.uv;
                
                float r_det = 1.0f / (deltaUV1.x * deltaUV2.y - deltaUV1.y * deltaUV2.x);
                float3 tangent = (edge1 * deltaUV2.y - edge2 * deltaUV1.y) * r_det;
                tangent = normalize(tangent - smoothNormal * dot(tangent, smoothNormal));
                float3 bitangent = cross(smoothNormal, tangent);
                float3x3 TBN = float3x3(tangent, bitangent, smoothNormal);
                
                float3 sampledNormal = sceneTextures[mat.normalMapIndex].sample(texSampler, hitUV).rgb;
                sampledNormal = sampledNormal * 2.0 - 1.0;
                normal = normalize(TBN * sampledNormal);
            }
            
            // Backface handling
            if (dot(r.direction, normal) > 0.0) {
                normal = -normal;
            }
            
            float3 hitPoint = r.origin + r.direction * intersection.distance;
            
            // Emission
            radiance += throughput * matAlbedo * mat.emission;
            
            // Direct lighting (shadow rays)
            for (uint l = 0; l < uniforms.lightCount; l++) {
                LightData light = lights[l];
                float3 lightDir = light.position - hitPoint;
                float distSq = dot(lightDir, lightDir);
                float dist = sqrt(distSq);
                lightDir /= dist;
                
                float NdotL = max(0.0, dot(normal, lightDir));
                if (NdotL > 0.0) {
                    ray shadow_ray;
                    shadow_ray.origin = hitPoint + normal * 0.001;
                    shadow_ray.direction = lightDir;
                    shadow_ray.min_distance = 0.001;
                    shadow_ray.max_distance = dist - 0.001;
                    
                    float3 shadow_tint = float3(1.0);
                    bool hit_light = false;
                    
                    for (int s_idx = 0; s_idx < 8; s_idx++) {
                        intersector<triangle_data> shadow_intersec;
                        shadow_intersec.accept_any_intersection(false); // We need the closest hit primitive
                        auto shadow_intersection = shadow_intersec.intersect(shadow_ray, accel);
                        
                        if (shadow_intersection.type == intersection_type::none) {
                            hit_light = true;
                            break;
                        }
                        
                        uint s_prim = shadow_intersection.primitive_id;
                        uint s_mat_id = materialIndices[s_prim];
                        MaterialData s_mat = materials[s_mat_id];
                        
                        // Determine if we can pass through this object
                        if (s_mat.transmission > 0.1) {
                            shadow_tint *= mix(float3(1.0), s_mat.albedo, s_mat.transmission);
                            // Advance the ray past this surface
                            shadow_ray.origin = shadow_ray.origin + shadow_ray.direction * shadow_intersection.distance + shadow_ray.direction * 0.001;
                            shadow_ray.max_distance -= shadow_intersection.distance;
                            if (shadow_ray.max_distance < 0.001) {
                                hit_light = true;
                                break;
                            }
                        } else {
                            break; // Opaque blocker
                        }
                    }
                    
                    if (hit_light) {
                        float attenuation = 1.0 / (distSq * 4.0 * 3.14159);
                        float3 V = normalize(-r.direction);
                        float3 L = lightDir;
                        float3 H = normalize(V + L);
                        
                        float NdotV = max(dot(normal, V), 0.0001f);
                        float NdotL_clamped = max(dot(normal, L), 0.0001f);
                        float NdotH = max(dot(normal, H), 0.0f);
                        float VdotH = max(dot(V, H), 0.0f);
                        
                        float3 F0 = mix(float3(0.04), matAlbedo, mat.metallic);
                        float3 F = schlick_fresnel(VdotH, F0);
                        float NDF = D_GGX(NdotH, mat.roughness);
                        float G = G_Smith(NdotV, NdotL_clamped, mat.roughness);
                        
                        float3 kS = F;
                        float3 kD = float3(1.0) - kS;
                        kD *= 1.0 - mat.metallic;
                        
                        float3 specular = (NDF * G * F) / (4.0 * NdotV * NdotL_clamped + 0.0001);
                        float3 brdf = (kD * matAlbedo / 3.14159) + specular;
                        
                        radiance += throughput * brdf * shadow_tint * light.color * light.power * attenuation * NdotL;
                    }
                }
            }
            
            // Indirect Path Sampling (Diffuse, Specular GGX, Refraction)
            float3 V_ind = normalize(-r.direction);
            float NdotV_ind = max(dot(normal, V_ind), 0.0001f);
            float3 F0_ind = mix(float3(0.04), matAlbedo, mat.metallic);
            float3 F_ind = schlick_fresnel(NdotV_ind, F0_ind);
            
            float randVal = random(state);
            float specularChance = clamp((F_ind.x + F_ind.y + F_ind.z) / 3.0f, 0.01f, 0.99f);
            float transmissionChance = clamp(mat.transmission * (1.0f - mat.metallic) * (1.0f - specularChance), 0.0f, 0.99f);
            
            if (randVal < specularChance) {
                // Specular Bounce (GGX)
                float3 H = sample_ggx(state, normal, mat.roughness);
                float3 L = normalize(reflect(-V_ind, H));
                float NdotL = max(dot(normal, L), 0.0001f);
                
                if (NdotL > 0.0) {
                    r.direction = L;
                    float NdotH = max(dot(normal, H), 0.0f);
                    float VdotH = max(dot(V_ind, H), 0.0f);
                    float G = G_Smith(NdotV_ind, NdotL, mat.roughness);
                    float weight = (VdotH * G) / (NdotV_ind * NdotH + 0.0001f);
                    throughput *= F_ind * weight / specularChance;
                } else {
                    break;
                }
            } else if (randVal < specularChance + transmissionChance) {
                // Transmission / Glass Refraction
                float etaI = 1.0;
                float etaT = mat.ior;
                float cosThetaI = dot(r.direction, normal);
                float3 n = normal;
                
                if (cosThetaI > 0.0) {
                    etaI = mat.ior;
                    etaT = 1.0;
                    n = -normal;
                }
                
                float eta = etaI / etaT;
                float3 refracted = refract(r.direction, n, eta);
                
                if (length_squared(refracted) < 0.001) {
                    // Total Internal Reflection - bounce as specular!
                    r.direction = reflect(r.direction, n);
                } else {
                    // Proper refraction
                    r.direction = refracted;
                }
                throughput *= matAlbedo / max(transmissionChance, 0.001f);
            } else {
                // Diffuse Bounce
                float3 L = sample_cosine_hemisphere(state, normal);
                r.direction = L;
                float3 kD = float3(1.0) - F_ind;
                kD *= 1.0 - mat.metallic;
                throughput *= kD * matAlbedo / max(1.0f - specularChance - transmissionChance, 0.001f);
            }
            
            // Push ray safely along outbound path to avoid self-shadowing
            r.origin = hitPoint + r.direction * 0.001;
            
            // basic russian roulette
            float p = max(throughput.x, max(throughput.y, throughput.z));
            if (random(state) > p) {
                break;
            }
            throughput /= p;
        }
        
        accumulatedColor += radiance;
    }
    
    float3 finalColor = accumulatedColor / float(SAMPLES);
    
    // ACES tonemapping
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    finalColor = clamp((finalColor * (a * finalColor + b)) / (finalColor * (c * finalColor + d) + e), 0.0, 1.0);
    
    // Gamma correction
    finalColor = pow(finalColor, float3(1.0 / 2.2));
    
    outTexture.write(float4(finalColor, 1.0), tid);
}
