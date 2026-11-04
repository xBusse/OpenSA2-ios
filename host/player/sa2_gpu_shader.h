// sa2_gpu_shader.h: an SDL_gpu shader made from SPIR-V on any device the build can serve.
//
// Every shader the players make is SPIR-V: the translator's (host/d3d9gpu, from DXVK's compiler
// through dxbc-spirv) and the touch overlay's (touch_overlay_shaders.py). A Vulkan device takes it
// as it is. A Metal device (the iOS app, host/ios; SDL_gpu has no Vulkan there) takes MSL only, so
// a build that defines SA2_HAVE_SHADERCROSS converts each module with SDL_shadercross, the path
// SDL's own tooling takes for Metal: SPIRV-Cross's MSL backend, with SDL's descriptor sets remapped
// to Metal's buffer and texture slots. MSL 2.3, so discard_fragment has the demote semantics a
// SPIR-V 1.6 module may ask for, as host/d3d9gpu/test/metal_check.py checks every specialised pixel
// shader converts.
//
// Header-only and inline, so a build without the converter (every desktop and the Android app)
// compiles it to the plain SDL_CreateGPUShader it had, and links nothing new.
#pragma once

#include <SDL3/SDL_gpu.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#if defined(SA2_HAVE_SHADERCROSS)
#include <SDL3_shadercross/SDL_shadercross.h>
#endif

namespace sa2_gpu {

// The MSL version the converter writes (SDL_shadercross's own default is 1.2.0).
constexpr const char kMslVersion[] = "2.3.0";

// Whether `dev` can make a shader from SPIR-V: as SPIR-V, or converted to MSL.
inline bool takes_spirv(SDL_GPUDevice* dev) {
    if (!dev) return false;
    const SDL_GPUShaderFormat f = SDL_GetGPUShaderFormats(dev);
    if (f & SDL_GPU_SHADERFORMAT_SPIRV) return true;
#if defined(SA2_HAVE_SHADERCROSS)
    if (f & SDL_GPU_SHADERFORMAT_MSL) return true;
#endif
    return false;
}

// "SPIR-V" or "MSL (SDL_shadercross)": what `dev` is given, for the reports; "none" when neither.
inline const char* path_name(SDL_GPUDevice* dev) {
    if (!dev) return "none";
    const SDL_GPUShaderFormat f = SDL_GetGPUShaderFormats(dev);
    if (f & SDL_GPU_SHADERFORMAT_SPIRV) return "SPIR-V";
#if defined(SA2_HAVE_SHADERCROSS)
    if (f & SDL_GPU_SHADERFORMAT_MSL) return "MSL (SDL_shadercross)";
#endif
    return "none";
}

// SDL_CreateGPUShader for the SPIR-V module `ci` describes (ci.format SPIRV), on a device that
// takes SPIR-V; on one that takes MSL, the module converted first, with the same resource counts.
// nullptr with `why` on failure.
inline SDL_GPUShader* shader_from_spirv(SDL_GPUDevice* dev, const SDL_GPUShaderCreateInfo& ci, std::string* why) {
    const SDL_GPUShaderFormat f = dev ? SDL_GetGPUShaderFormats(dev) : 0;
    if (f & SDL_GPU_SHADERFORMAT_SPIRV) {
        SDL_GPUShader* s = SDL_CreateGPUShader(dev, &ci);
        if (!s && why) *why = std::string("SDL_CreateGPUShader: ") + SDL_GetError();
        return s;
    }
#if defined(SA2_HAVE_SHADERCROSS)
    if (f & SDL_GPU_SHADERFORMAT_MSL) {
        static const bool ready = SDL_ShaderCross_Init();
        if (!ready) {
            if (why) *why = std::string("SDL_ShaderCross_Init: ") + SDL_GetError();
            return nullptr;
        }
        const SDL_PropertiesID props = SDL_CreateProperties();
        if (props) SDL_SetStringProperty(props, SDL_SHADERCROSS_PROP_SPIRV_MSL_VERSION_STRING, kMslVersion);
        SDL_ShaderCross_SPIRV_Info info{};
        info.bytecode = ci.code;
        info.bytecode_size = ci.code_size;
        info.entrypoint = ci.entrypoint ? ci.entrypoint : "main";
        info.shader_stage = ci.stage == SDL_GPU_SHADERSTAGE_VERTEX ? SDL_SHADERCROSS_SHADERSTAGE_VERTEX
                                                                   : SDL_SHADERCROSS_SHADERSTAGE_FRAGMENT;
        info.props = props;
        // The module is converted to MSL here and made by SDL with the caller's resource counts. SDL_shadercross's
        // own CompileGraphicsShaderFromSPIRV counts the resources by reflection instead, so a shader that uses
        // uniform slots 1 and 3 of its four (the translator's vertex shaders: the constants and the state) is
        // made with two, SDL's Metal backend binds only buffers 0 and 1, and slot 3 reads whatever buffer was
        // left there (GitHub issue #2: Chao World's palette lighting). The MSL keeps each SPIR-V binding as its
        // Metal index (SDL_shadercross's rule, which is SDL's slot), and SPIRV-Cross names the entry main0.
        void* msl = SDL_ShaderCross_TranspileMSLFromSPIRV(&info);
        if (!msl) {
            if (why) *why = std::string("SDL_ShaderCross_TranspileMSLFromSPIRV (MSL ") + kMslVersion + "): " + SDL_GetError();
            if (props) SDL_DestroyProperties(props);
            return nullptr;
        }
        // SA2_IOS_MSL_DUMP (a directory; the iOS app's Debug switch sets it in the session): each module and
        // the MSL made from it, NNN_<stage>_s<samplers>_u<uniform buffers>.spv and .metal.
        if (const char* dir = std::getenv("SA2_IOS_MSL_DUMP"); dir && *dir) {
            static std::atomic<int> dumped{0};
            const int n = dumped++;
            char base[1024];
            std::snprintf(base, sizeof base, "%s/%03d_%s_s%u_u%u", dir, n,
                          ci.stage == SDL_GPU_SHADERSTAGE_VERTEX ? "vs" : "ps", ci.num_samplers, ci.num_uniform_buffers);
            if (FILE* fs = std::fopen((std::string(base) + ".spv").c_str(), "wb")) {
                std::fwrite(ci.code, 1, ci.code_size, fs);
                std::fclose(fs);
            }
            if (FILE* fm = std::fopen((std::string(base) + ".metal").c_str(), "wb")) {
                std::fputs(static_cast<const char*>(msl), fm);
                std::fclose(fm);
            }
        }
        SDL_GPUShaderCreateInfo mci = ci;
        mci.code = static_cast<const Uint8*>(msl);
        mci.code_size = std::strlen(static_cast<const char*>(msl));
        mci.entrypoint = "main0";
        mci.format = SDL_GPU_SHADERFORMAT_MSL;
        SDL_GPUShader* s = SDL_CreateGPUShader(dev, &mci);
        if (!s && why) *why = std::string("SDL_CreateGPUShader (MSL ") + kMslVersion + "): " + SDL_GetError();
        SDL_free(msl);
        if (props) SDL_DestroyProperties(props);
        return s;
    }
#endif
    if (why) *why = "the GPU device takes no shader format this build can make from SPIR-V";
    return nullptr;
}

}  // namespace sa2_gpu
