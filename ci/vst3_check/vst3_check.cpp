/*
 * Wolf Shaper CI checks: a small VST3 host (ci/vst3_check)
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copyright (C) 2026 Sonic Weaponry
 */

// Loads a VST3 bundle the way a host does, runs one check, and exits. One check per process, so a crash in one can't
// hide the other results (ci/run_checks.sh runs all four).
//
//   vst3_check ids <bundle> <ours|official> <class-ids.txt>
//       Class IDs read through the VST3 SDK's own FUID code (what hosts store in projects), against the frozen table,
//       then again after the module's exit function and a second entry.
//   vst3_check params <bundle> <parameters.json> [<write to>]
//       Every parameter the controller lists, plus the state symbol each one is saved under, against the frozen table.
//   vst3_check states <bundle> <state file>...
//       Each state loads into a fresh instance and saves back byte for byte, and the controller shows its values under
//       the right IDs. Then all of them again, one after another, in a single instance.
//   vst3_check instance <bundle> <plugin-info.json> [<write to>]
//       Creates the component from its class ID and the controller from getControllerClassId, connects them as a host
//       does, and compares what a host sees (names, versions, buses) with the frozen table.
//
// Exit code: 0 when the check passes, 1 when it fails, 2 for a usage error. The last line printed is always
// "RESULT <check> PASS|FAIL <detail>".

#if defined(_WIN32)
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#endif

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#define CHECK_OS "windows"
#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#define CHECK_OS "macos"
#else
#include <dlfcn.h>
#define CHECK_OS "linux"
#endif

#if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64)
#define CHECK_CPU "arm64"
#elif defined(__x86_64__) || defined(_M_X64)
#define CHECK_CPU "x86_64"
#else
#define CHECK_CPU "other"
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

// --------------------------------------------------------------------------------------------------------------------
// Small helpers

static bool readFile(const std::string& path, std::string& data)
{
    std::ifstream file(path, std::ios::binary);
    if (!file.good())
        return false;
    data.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    return true;
}

static bool writeFile(const std::string& path, const std::string& data)
{
    std::ofstream file(path, std::ios::binary);
    file << data;
    return file.good();
}

static std::string withoutCarriageReturns(std::string text)
{
    text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
    return text;
}

static std::vector<std::string> splitLines(const std::string& text)
{
    std::vector<std::string> lines;
    std::istringstream stream(text);
    for (std::string line; std::getline(stream, line);)
        lines.push_back(line);
    return lines;
}

static std::string baseName(std::string path)
{
    while (!path.empty() && (path.back() == '/' || path.back() == '\\'))
        path.pop_back();
    const size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

static std::string toUtf8(const char16* text, size_t capacity)
{
    std::string out;
    for (size_t i = 0; i < capacity && text[i] != 0; ++i)
    {
        uint32 c = static_cast<uint16>(text[i]);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < capacity)
        {
            const uint32 low = static_cast<uint16>(text[i + 1]);
            if (low >= 0xDC00 && low <= 0xDFFF)
            {
                c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                ++i;
            }
        }
        if (c < 0x80)
        {
            out += static_cast<char>(c);
        }
        else if (c < 0x800)
        {
            out += static_cast<char>(0xC0 | (c >> 6));
            out += static_cast<char>(0x80 | (c & 0x3F));
        }
        else if (c < 0x10000)
        {
            out += static_cast<char>(0xE0 | (c >> 12));
            out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (c & 0x3F));
        }
        else
        {
            out += static_cast<char>(0xF0 | (c >> 18));
            out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (c & 0x3F));
        }
    }
    return out;
}

static std::string cString(const char8* text, size_t capacity)
{
    size_t length = 0;
    while (length < capacity && text[length] != 0)
        ++length;
    return std::string(text, length);
}

static std::string rawBytes(const TUID id)
{
    char text[16 * 3 + 1] = {};
    for (int b = 0; b < 16; ++b)
        std::snprintf(text + b * 3, 4, b < 15 ? "%02X " : "%02X", static_cast<unsigned>(static_cast<unsigned char>(id[b])));
    return text;
}

// The ID the VST3 SDK makes of these 16 bytes on this platform (FUID::toString), the form hosts compare and store.
static std::string canonicalId(const TUID id)
{
    char text[33] = {};
    FUID::fromTUID(id).toString(text);
    return text;
}

static const char* resultName(tresult result)
{
    if (result == kResultOk)
        return "ok";
    if (result == kResultFalse)
        return "false";
    if (result == kNoInterface)
        return "no_interface";
    if (result == kInvalidArgument)
        return "invalid_argument";
    if (result == kNotImplemented)
        return "not_implemented";
    if (result == kInternalError)
        return "internal_error";
    if (result == kNotInitialized)
        return "not_initialized";
    if (result == kOutOfMemory)
        return "out_of_memory";
    return "other";
}

// Bytes made readable for the log: printable ASCII as is, NUL as \0, anything else as \xNN.
static std::string printable(const std::string& bytes)
{
    std::string out;
    for (unsigned char c : bytes)
    {
        if (c == 0)
        {
            out += "\\0";
        }
        else if (c >= 0x20 && c < 0x7F && c != '\\')
        {
            out += static_cast<char>(c);
        }
        else
        {
            char hex[8];
            std::snprintf(hex, sizeof(hex), "\\x%02X", static_cast<unsigned>(c));
            out += hex;
        }
    }
    return out;
}

static std::string jsonString(const std::string& text)
{
    std::string out = "\"";
    for (unsigned char c : text)
    {
        switch (c)
        {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (c < 0x20)
            {
                char escaped[8];
                std::snprintf(escaped, sizeof(escaped), "\\u%04x", static_cast<unsigned>(c));
                out += escaped;
            }
            else
            {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

static std::string jsonNumber(double value)
{
    if (!std::isfinite(value))
        return "null";
    if (value == 0.0)
        return "0";
    char text[40];
    std::snprintf(text, sizeof(text), "%.17g", value);
    return text;
}

static std::string jsonInt(long long value)
{
    return std::to_string(value);
}

// Compares generated text with a frozen file (line endings ignored) and prints the lines that differ.
static bool matchesFrozen(const std::string& frozenPath, const std::string& generated, std::string& detail)
{
    std::string frozen;
    if (!readFile(frozenPath, frozen))
    {
        detail = "no frozen table at " + frozenPath;
        return false;
    }
    frozen = withoutCarriageReturns(frozen);
    if (frozen == generated)
    {
        detail = "matches " + frozenPath;
        return true;
    }

    const std::vector<std::string> want = splitLines(frozen), got = splitLines(generated);
    size_t differing = 0;
    for (size_t i = 0; i < std::max(want.size(), got.size()); ++i)
    {
        const std::string a = i < want.size() ? want[i] : "(no line)";
        const std::string b = i < got.size() ? got[i] : "(no line)";
        if (a == b)
            continue;
        if (++differing <= 30)
            std::printf("DIFF line %zu\n  frozen: %s\n  got:    %s\n", i + 1, a.c_str(), b.c_str());
    }
    detail = "differs from " + frozenPath + " in " + std::to_string(differing) + " line(s)";
    return false;
}

// --------------------------------------------------------------------------------------------------------------------
// Host side objects. They live for the whole process, so reference counting is a no-op.

class HostApplication : public IHostApplication
{
public:
    tresult PLUGIN_API getName(String128 name) override
    {
        const char* text = "vst3_check";
        size_t i = 0;
        for (; text[i] != 0 && i < 127; ++i)
            name[i] = static_cast<char16>(text[i]);
        name[i] = 0;
        return kResultOk;
    }

    // No IMessage / IAttributeList support yet: the checks never open the editor, so DPF never asks for them.
    tresult PLUGIN_API createInstance(TUID, TUID, void** obj) override
    {
        *obj = nullptr;
        return kNotImplemented;
    }

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override
    {
        if (FUnknownPrivate::iidEqual(iid, FUnknown_iid) || FUnknownPrivate::iidEqual(iid, IHostApplication_iid))
        {
            *obj = static_cast<IHostApplication*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return 1000; }
    uint32 PLUGIN_API release() override { return 1000; }
};

class ComponentHandler : public IComponentHandler
{
public:
    int restarts = 0;

    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID, ParamValue) override { return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override
    {
        ++restarts;
        return kResultOk;
    }

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override
    {
        if (FUnknownPrivate::iidEqual(iid, FUnknown_iid) || FUnknownPrivate::iidEqual(iid, IComponentHandler_iid))
        {
            *obj = static_cast<IComponentHandler*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return 1000; }
    uint32 PLUGIN_API release() override { return 1000; }
};

// The stream a host hands to setState / getState: a plain growable byte buffer.
class MemoryStream : public IBStream
{
public:
    std::string data;
    int64 position = 0;

    MemoryStream() {}
    explicit MemoryStream(const std::string& bytes) : data(bytes) {}

    tresult PLUGIN_API read(void* buffer, int32 numBytes, int32* numBytesRead) override
    {
        if (numBytes < 0)
            return kInvalidArgument;
        const int64 available = std::max<int64>(0, static_cast<int64>(data.size()) - position);
        const int32 count = static_cast<int32>(std::min<int64>(numBytes, available));
        if (count > 0)
            std::memcpy(buffer, data.data() + position, static_cast<size_t>(count));
        position += count;
        if (numBytesRead != nullptr)
            *numBytesRead = count;
        return kResultOk;
    }

    tresult PLUGIN_API write(void* buffer, int32 numBytes, int32* numBytesWritten) override
    {
        if (numBytes < 0)
            return kInvalidArgument;
        const size_t end = static_cast<size_t>(position) + static_cast<size_t>(numBytes);
        if (end > data.size())
            data.resize(end);
        if (numBytes > 0)
            std::memcpy(&data[static_cast<size_t>(position)], buffer, static_cast<size_t>(numBytes));
        position += numBytes;
        if (numBytesWritten != nullptr)
            *numBytesWritten = numBytes;
        return kResultOk;
    }

    tresult PLUGIN_API seek(int64 pos, int32 mode, int64* result) override
    {
        int64 target = pos;
        if (mode == kIBSeekCur)
            target = position + pos;
        else if (mode == kIBSeekEnd)
            target = static_cast<int64>(data.size()) + pos;
        else if (mode != kIBSeekSet)
            return kInvalidArgument;
        if (target < 0)
            return kInvalidArgument;
        position = target;
        if (result != nullptr)
            *result = position;
        return kResultOk;
    }

    tresult PLUGIN_API tell(int64* pos) override
    {
        if (pos == nullptr)
            return kInvalidArgument;
        *pos = position;
        return kResultOk;
    }

    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override
    {
        if (FUnknownPrivate::iidEqual(iid, FUnknown_iid) || FUnknownPrivate::iidEqual(iid, IBStream_iid))
        {
            *obj = static_cast<IBStream*>(this);
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 PLUGIN_API addRef() override { return 1000; }
    uint32 PLUGIN_API release() override { return 1000; }
};

static HostApplication gHost;
static ComponentHandler gHandler;

// --------------------------------------------------------------------------------------------------------------------
// The module: loaded with the platform's entry and exit functions, like a host does. Once per process, except that the
// ids check enters it a second time.

typedef IPluginFactory*(PLUGIN_API* GetFactoryProc)();
typedef bool (*ExitProc)();

struct Module
{
    IPluginFactory* factory = nullptr;
    ExitProc exitProc = nullptr;

    bool load(const std::string& bundle)
    {
#if defined(_WIN32)
        std::string binary = bundle + "/Contents/x86_64-win/" + baseName(bundle);
        std::replace(binary.begin(), binary.end(), '/', '\\');
        HMODULE module = LoadLibraryA(binary.c_str());
        if (module == nullptr)
        {
            std::printf("ERROR LoadLibrary failed for %s (error %lu)\n", binary.c_str(), GetLastError());
            return false;
        }
        typedef bool (*InitProc)();
        if (InitProc init = reinterpret_cast<InitProc>(GetProcAddress(module, "InitDll")))
            init();
        exitProc = reinterpret_cast<ExitProc>(GetProcAddress(module, "ExitDll"));
        GetFactoryProc proc = reinterpret_cast<GetFactoryProc>(GetProcAddress(module, "GetPluginFactory"));
#elif defined(__APPLE__)
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(bundle.c_str()),
                                                               static_cast<CFIndex>(bundle.size()), true);
        CFBundleRef module = url != nullptr ? CFBundleCreate(nullptr, url) : nullptr;
        if (url != nullptr)
            CFRelease(url);
        if (module == nullptr || !CFBundleLoadExecutable(module))
        {
            std::printf("ERROR could not load the bundle %s\n", bundle.c_str());
            return false;
        }
        typedef bool (*EntryProc)(CFBundleRef);
        if (EntryProc entry = reinterpret_cast<EntryProc>(CFBundleGetFunctionPointerForName(module, CFSTR("bundleEntry"))))
            entry(module);
        exitProc = reinterpret_cast<ExitProc>(CFBundleGetFunctionPointerForName(module, CFSTR("bundleExit")));
        GetFactoryProc proc =
            reinterpret_cast<GetFactoryProc>(CFBundleGetFunctionPointerForName(module, CFSTR("GetPluginFactory")));
#else
        std::string name = baseName(bundle);
        const size_t dot = name.rfind('.');
        if (dot != std::string::npos)
            name = name.substr(0, dot);
        const std::string binary = bundle + "/Contents/" CHECK_CPU "-linux/" + name + ".so";
        void* module = dlopen(binary.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (module == nullptr)
        {
            std::printf("ERROR dlopen failed: %s\n", dlerror());
            return false;
        }
        typedef bool (*EntryProc)(void*);
        if (EntryProc entry = reinterpret_cast<EntryProc>(dlsym(module, "ModuleEntry")))
            entry(module);
        exitProc = reinterpret_cast<ExitProc>(dlsym(module, "ModuleExit"));
        GetFactoryProc proc = reinterpret_cast<GetFactoryProc>(dlsym(module, "GetPluginFactory"));
#endif
        if (proc == nullptr)
        {
            std::printf("ERROR no GetPluginFactory in %s\n", bundle.c_str());
            return false;
        }
        factory = proc();
        if (factory == nullptr)
        {
            std::printf("ERROR GetPluginFactory returned nothing\n");
            return false;
        }
        return true;
    }

    // Hosts release the factory and call the exit function before they unload a module. The library itself stays
    // loaded until the process ends.
    void unload()
    {
        if (factory != nullptr)
        {
            factory->release();
            factory = nullptr;
        }
        if (exitProc != nullptr)
        {
            exitProc();
            exitProc = nullptr;
        }
    }
};

struct ClassIds
{
    bool haveComponent = false;
    bool haveController = false;
    TUID component = {};
    TUID controller = {};
};

static ClassIds findClasses(IPluginFactory* factory)
{
    ClassIds ids;
    for (int32 i = 0, count = factory->countClasses(); i < count; ++i)
    {
        PClassInfo info{};
        if (factory->getClassInfo(i, &info) != kResultOk)
            continue;
        if (std::strcmp(info.category, kVstAudioEffectClass) == 0 && !ids.haveComponent)
        {
            std::memcpy(ids.component, info.cid, sizeof(TUID));
            ids.haveComponent = true;
        }
        else if (std::strcmp(info.category, kVstComponentControllerClass) == 0 && !ids.haveController)
        {
            std::memcpy(ids.controller, info.cid, sizeof(TUID));
            ids.haveController = true;
        }
    }
    return ids;
}

// Lets the factory see the host, as hosts do right after loading a module (IPluginFactory3::setHostContext).
static tresult setHostContext(IPluginFactory* factory)
{
    IPluginFactory3* factory3 = nullptr;
    if (factory->queryInterface(IPluginFactory3_iid, reinterpret_cast<void**>(&factory3)) != kResultOk ||
        factory3 == nullptr)
        return kNoInterface;
    const tresult result = factory3->setHostContext(&gHost);
    factory3->release();
    return result;
}

// --------------------------------------------------------------------------------------------------------------------
// One plugin instance, opened in the order the VST3 SDK's own hosting code (PlugProvider) uses: component, then the
// controller named by getControllerClassId, then the two connected through their connection points.

struct Session
{
    IComponent* component = nullptr;
    IEditController* controller = nullptr;
    IConnectionPoint* componentPoint = nullptr;
    IConnectionPoint* controllerPoint = nullptr;
    bool connected = false;
    bool ok = true;
    std::vector<std::string> steps;
    std::string error;

    bool step(const std::string& what, tresult result)
    {
        steps.push_back(what + ": " + resultName(result));
        if (result != kResultOk)
        {
            ok = false;
            if (error.empty())
                error = what + " returned " + resultName(result);
        }
        return result == kResultOk;
    }

    bool fail(const std::string& why)
    {
        steps.push_back("FAILED: " + why);
        ok = false;
        if (error.empty())
            error = why;
        return false;
    }

    bool open(IPluginFactory* factory, const ClassIds& ids)
    {
        if (!ids.haveComponent)
            return fail("the factory lists no Audio Module Class");
        if (!ids.haveController)
            return fail("the factory lists no Component Controller Class");

        if (!step("create the component from its class ID",
                  factory->createInstance(ids.component, IComponent_iid, reinterpret_cast<void**>(&component))))
            return false;
        if (component == nullptr)
            return fail("createInstance returned no component");
        if (!step("initialize the component", component->initialize(&gHost)))
            return false;

        TUID controllerId = {};
        if (!step("getControllerClassId", component->getControllerClassId(controllerId)))
            return false;
        if (std::memcmp(controllerId, ids.controller, sizeof(TUID)) != 0)
            return fail("getControllerClassId gives " + canonicalId(controllerId) + " but the factory lists " +
                        canonicalId(ids.controller));
        steps.push_back("getControllerClassId matches the factory's controller class: " + canonicalId(controllerId));

        if (!step("create the controller from that class ID",
                  factory->createInstance(controllerId, IEditController_iid, reinterpret_cast<void**>(&controller))))
            return false;
        if (controller == nullptr)
            return fail("createInstance returned no controller");
        if (!step("initialize the controller", controller->initialize(&gHost)))
            return false;
        if (!step("setComponentHandler", controller->setComponentHandler(&gHandler)))
            return false;

        const tresult componentHasPoint =
            component->queryInterface(IConnectionPoint_iid, reinterpret_cast<void**>(&componentPoint));
        const tresult controllerHasPoint =
            controller->queryInterface(IConnectionPoint_iid, reinterpret_cast<void**>(&controllerPoint));
        steps.push_back(std::string("component connection point: ") + resultName(componentHasPoint));
        steps.push_back(std::string("controller connection point: ") + resultName(controllerHasPoint));
        if (componentHasPoint != kResultOk)
            componentPoint = nullptr;
        if (controllerHasPoint != kResultOk)
            controllerPoint = nullptr;
        if (componentPoint != nullptr && controllerPoint != nullptr)
        {
            if (!step("connect component to controller", componentPoint->connect(controllerPoint)))
                return false;
            if (!step("connect controller to component", controllerPoint->connect(componentPoint)))
                return false;
            connected = true;
        }
        return true;
    }

    // Tears down in the reverse order, releasing every interface we asked for before the objects themselves.
    void close()
    {
        if (connected)
        {
            step("disconnect component from controller", componentPoint->disconnect(controllerPoint));
            step("disconnect controller from component", controllerPoint->disconnect(componentPoint));
            connected = false;
        }
        if (componentPoint != nullptr)
        {
            componentPoint->release();
            componentPoint = nullptr;
        }
        if (controllerPoint != nullptr)
        {
            controllerPoint->release();
            controllerPoint = nullptr;
        }
        if (controller != nullptr)
        {
            step("clear the component handler", controller->setComponentHandler(nullptr));
            step("terminate the controller", controller->terminate());
            controller->release();
            controller = nullptr;
        }
        if (component != nullptr)
        {
            step("terminate the component", component->terminate());
            component->release();
            component = nullptr;
        }
    }

    void printSteps(const char* prefix) const
    {
        for (const std::string& line : steps)
            std::printf("%s%s\n", prefix, line.c_str());
    }
};

static tresult loadComponentState(IComponent* component, const std::string& state)
{
    MemoryStream stream(state);
    return component->setState(&stream);
}

static tresult saveComponentState(IComponent* component, std::string& state)
{
    MemoryStream stream;
    const tresult result = component->getState(&stream);
    state = stream.data;
    return result;
}

static tresult loadControllerState(IEditController* controller, const std::string& state)
{
    MemoryStream stream(state);
    return controller->setComponentState(&stream);
}

// --------------------------------------------------------------------------------------------------------------------
// DPF's state format: NUL-separated text. "__dpf_state_begin__", key, value..., "__dpf_state_end__",
// "__dpf_parameters_begin__", symbol, value..., "__dpf_parameters_end__", then the terminator byte 0xFE and a NUL.

static std::vector<std::string> splitState(const std::string& state)
{
    std::vector<std::string> tokens;
    size_t start = 0;
    for (size_t i = 0; i < state.size(); ++i)
    {
        if (state[i] == '\0')
        {
            tokens.push_back(state.substr(start, i - start));
            start = i + 1;
        }
    }
    tokens.push_back(state.substr(start));
    return tokens;
}

static std::string joinState(const std::vector<std::string>& tokens)
{
    std::string state;
    for (size_t i = 0; i < tokens.size(); ++i)
    {
        if (i > 0)
            state += '\0';
        state += tokens[i];
    }
    return state;
}

struct StateValue
{
    size_t token; // index of the symbol in the token list; its value is the next token
    std::string symbol;
    std::string value;
};

static bool stateParameters(const std::vector<std::string>& tokens, std::vector<StateValue>& values)
{
    values.clear();
    size_t i = 0;
    while (i < tokens.size() && tokens[i] != "__dpf_parameters_begin__")
        ++i;
    if (i == tokens.size())
        return false;
    for (++i; i + 1 < tokens.size() && tokens[i] != "__dpf_parameters_end__"; i += 2)
        values.push_back(StateValue{i, tokens[i], tokens[i + 1]});
    return i < tokens.size() && tokens[i] == "__dpf_parameters_end__";
}

// Where two states first differ, plus every parameter whose saved text differs.
static void printStateDifference(const std::string& want, const std::string& got)
{
    size_t at = 0;
    while (at < want.size() && at < got.size() && want[at] == got[at])
        ++at;
    const size_t from = at > 24 ? at - 24 : 0;
    std::printf("  sizes: frozen %zu bytes, got %zu bytes; first difference at byte %zu\n", want.size(), got.size(), at);
    std::printf("  frozen: ...%s...\n", printable(want.substr(from, 64)).c_str());
    std::printf("  got:    ...%s...\n", printable(got.substr(from, 64)).c_str());

    std::vector<StateValue> a, b;
    stateParameters(splitState(want), a);
    stateParameters(splitState(got), b);
    std::map<std::string, std::string> gotValues;
    for (const StateValue& v : b)
        gotValues[v.symbol] = v.value;
    for (const StateValue& v : a)
    {
        const auto it = gotValues.find(v.symbol);
        if (it == gotValues.end())
            std::printf("  parameter %s: frozen \"%s\", missing in the saved state\n", v.symbol.c_str(), v.value.c_str());
        else if (it->second != v.value)
            std::printf("  parameter %s: frozen \"%s\", saved back as \"%s\"\n", v.symbol.c_str(), v.value.c_str(),
                        it->second.c_str());
    }
}

// --------------------------------------------------------------------------------------------------------------------
// Parameters, as the controller lists them to a host

struct Parameter
{
    ParameterInfo info{};
    std::string title, shortTitle, units;
    std::string symbol; // the key DPF saves this parameter's value under; empty when it isn't saved
    double min = 0, max = 0, def = 0;
    std::vector<std::string> stepLabels;
};

static double plainValue(IEditController* controller, ParamID id)
{
    return controller->normalizedParamToPlain(id, controller->getParamNormalized(id));
}

static bool sameValue(double a, double b)
{
    return std::fabs(a - b) <= 1e-6 * std::max(1.0, std::fabs(b));
}

static bool listParameters(IEditController* controller, std::vector<Parameter>& parameters, std::string& error)
{
    parameters.clear();
    const int32 count = controller->getParameterCount();
    for (int32 i = 0; i < count; ++i)
    {
        Parameter p;
        const tresult result = controller->getParameterInfo(i, p.info);
        if (result != kResultOk)
        {
            error = "getParameterInfo(" + std::to_string(i) + ") returned " + resultName(result);
            return false;
        }
        p.title = toUtf8(p.info.title, 128);
        p.shortTitle = toUtf8(p.info.shortTitle, 128);
        p.units = toUtf8(p.info.units, 128);
        p.min = controller->normalizedParamToPlain(p.info.id, 0.0);
        p.max = controller->normalizedParamToPlain(p.info.id, 1.0);
        p.def = controller->normalizedParamToPlain(p.info.id, p.info.defaultNormalizedValue);
        if (p.info.stepCount > 0 && p.info.stepCount <= 16)
        {
            for (int32 s = 0; s <= p.info.stepCount; ++s)
            {
                String128 label = {};
                const ParamValue normalized = static_cast<ParamValue>(s) / p.info.stepCount;
                if (controller->getParamStringByValue(p.info.id, normalized, label) == kResultOk)
                    p.stepLabels.push_back(toUtf8(label, 128));
                else
                    p.stepLabels.push_back("(no label)");
            }
        }
        parameters.push_back(p);
    }
    return true;
}

// Which VST3 parameter each saved symbol lands on: load a state that changes only that symbol and see which parameter
// moves. Measured through the controller, which is how saved values reach a host's automation and mappings.
static bool mapSymbols(Session& session, std::vector<Parameter>& parameters, std::string& error)
{
    std::string defaults;
    tresult result = saveComponentState(session.component, defaults);
    if (result != kResultOk)
    {
        error = std::string("getState of a fresh component returned ") + resultName(result);
        return false;
    }
    std::vector<std::string> tokens = splitState(defaults);
    std::vector<StateValue> saved;
    if (!stateParameters(tokens, saved))
    {
        error = "the default state has no parameter section";
        return false;
    }

    result = loadControllerState(session.controller, defaults);
    if (result != kResultOk)
    {
        error = std::string("setComponentState with the default state returned ") + resultName(result);
        return false;
    }
    std::vector<double> baseline;
    for (const Parameter& p : parameters)
        baseline.push_back(plainValue(session.controller, p.info.id));

    bool ok = true;
    for (const StateValue& v : saved)
    {
        std::vector<std::string> changed = tokens;
        changed[v.token + 1] = std::strtod(v.value.c_str(), nullptr) != 0.0 ? "0" : "1";
        loadControllerState(session.controller, joinState(changed));

        std::vector<size_t> moved;
        for (size_t i = 0; i < parameters.size(); ++i)
            if (!sameValue(plainValue(session.controller, parameters[i].info.id), baseline[i]))
                moved.push_back(i);
        loadControllerState(session.controller, defaults);

        if (moved.size() == 1)
        {
            parameters[moved[0]].symbol = v.symbol;
        }
        else
        {
            ok = false;
            error += (error.empty() ? "" : "; ") + std::string("symbol ") + v.symbol + " moved " +
                     std::to_string(moved.size()) + " parameters";
        }
    }
    return ok;
}

static std::string flagNames(int32 flags)
{
    static const struct
    {
        int32 bit;
        const char* name;
    } names[] = {
        {ParameterInfo::kCanAutomate, "can_automate"}, {ParameterInfo::kIsReadOnly, "read_only"},
        {ParameterInfo::kIsWrapAround, "wrap_around"}, {ParameterInfo::kIsList, "list"},
        {ParameterInfo::kIsHidden, "hidden"},          {ParameterInfo::kIsProgramChange, "program_change"},
        {ParameterInfo::kIsBypass, "bypass"},
    };
    std::string out = "[";
    int32 known = 0;
    for (const auto& n : names)
    {
        known |= n.bit;
        if (flags & n.bit)
            out += (out.size() > 1 ? ", " : "") + jsonString(n.name);
    }
    for (int bit = 0; bit < 31; ++bit)
        if ((flags & ~known) & (1 << bit))
            out += (out.size() > 1 ? ", " : "") + jsonString("bit" + std::to_string(bit));
    return out + "]";
}

static std::string parametersJson(const std::vector<Parameter>& parameters)
{
    std::string json = "{\n";
    json += "  \"format\": \"wolf-shaper ci/vst3_check params 1\",\n";
    json += "  \"parameter_count\": " + jsonInt(static_cast<long long>(parameters.size())) + ",\n";
    json += "  \"parameters\": [\n";
    for (size_t i = 0; i < parameters.size(); ++i)
    {
        const Parameter& p = parameters[i];
        std::string labels = "null";
        if (!p.stepLabels.empty())
        {
            labels = "[";
            for (size_t s = 0; s < p.stepLabels.size(); ++s)
                labels += (s > 0 ? ", " : "") + jsonString(p.stepLabels[s]);
            labels += "]";
        }
        json += "    {\n";
        json += "      \"index\": " + jsonInt(static_cast<long long>(i)) + ",\n";
        json += "      \"id\": " + jsonInt(p.info.id) + ",\n";
        json += "      \"symbol\": " + (p.symbol.empty() ? std::string("null") : jsonString(p.symbol)) + ",\n";
        json += "      \"title\": " + jsonString(p.title) + ",\n";
        json += "      \"short_title\": " + jsonString(p.shortTitle) + ",\n";
        json += "      \"units\": " + jsonString(p.units) + ",\n";
        json += "      \"min\": " + jsonNumber(p.min) + ",\n";
        json += "      \"max\": " + jsonNumber(p.max) + ",\n";
        json += "      \"default\": " + jsonNumber(p.def) + ",\n";
        json += "      \"default_normalized\": " + jsonNumber(p.info.defaultNormalizedValue) + ",\n";
        json += "      \"step_count\": " + jsonInt(p.info.stepCount) + ",\n";
        json += "      \"step_labels\": " + labels + ",\n";
        json += "      \"flags\": " + flagNames(p.info.flags) + ",\n";
        json += "      \"unit_id\": " + jsonInt(p.info.unitId) + "\n";
        json += std::string("    }") + (i + 1 < parameters.size() ? "," : "") + "\n";
    }
    json += "  ]\n}\n";
    return json;
}

// --------------------------------------------------------------------------------------------------------------------
// Check: class IDs

// What a plugin built on the VST3 SDK (as JUCE plugins are) hands the host on this platform for the class ID the
// official Windows build reports. Printed for reference only.
static void printSdkReference()
{
    const FUID reference(0x44504620, 0x6173636C, 0x70735773, 0x00000000);
    TUID bytes;
    reference.toTUID(bytes);
    std::printf("SDK_REFERENCE|%s|%s|COM_COMPATIBLE=%d|FUID(0x44504620,0x6173636C,0x70735773,0)|%s|%s\n", CHECK_OS,
                CHECK_CPU, static_cast<int>(COM_COMPATIBLE), rawBytes(bytes).c_str(), canonicalId(bytes).c_str());
}

static bool checkIds(Module& module, const std::string& build, const std::string& frozenPath, std::string& detail)
{
    std::string frozen;
    if (!readFile(frozenPath, frozen))
    {
        detail = "no frozen table at " + frozenPath;
        return false;
    }
    std::map<std::string, std::string> expected;
    for (std::string line : splitLines(withoutCarriageReturns(frozen)))
    {
        const size_t hash = line.find('#');
        if (hash != std::string::npos)
            line.erase(hash);
        std::istringstream fields(line);
        std::string platform, which, kind, id;
        if (!(fields >> platform >> which >> kind >> id))
            continue;
        if (platform == CHECK_OS && which == build)
            expected[kind] = id;
    }
    if (expected.count("component") == 0 || expected.count("controller") == 0)
    {
        detail = std::string("no frozen component and controller IDs for ") + CHECK_OS + " " + build + " in " + frozenPath;
        return false;
    }

    printSdkReference();
    IPluginFactory* factory = module.factory;
    PFactoryInfo factoryInfo{};
    factory->getFactoryInfo(&factoryInfo);
    std::printf("FACTORY|%s|%s|vendor=%s\n", CHECK_OS, CHECK_CPU, cString(factoryInfo.vendor, PFactoryInfo::kNameSize).c_str());

    IPluginFactory2* factory2 = nullptr;
    IPluginFactory3* factory3 = nullptr;
    if (factory->queryInterface(IPluginFactory2_iid, reinterpret_cast<void**>(&factory2)) != kResultOk)
        factory2 = nullptr;
    if (factory->queryInterface(IPluginFactory3_iid, reinterpret_cast<void**>(&factory3)) != kResultOk)
        factory3 = nullptr;

    bool ok = true;
    std::map<std::string, std::string> got;
    const int32 count = factory->countClasses();
    for (int32 i = 0; i < count; ++i)
    {
        PClassInfo info{};
        if (factory->getClassInfo(i, &info) != kResultOk)
        {
            std::printf("ERROR getClassInfo(%d) failed\n", static_cast<int>(i));
            ok = false;
            continue;
        }
        const FUID fuid = FUID::fromTUID(info.cid);
        std::printf("CLASS|%s|%s|COM_COMPATIBLE=%d|%s|%s|%s|%s|%d,%d,%d,%d\n", CHECK_OS, CHECK_CPU,
                    static_cast<int>(COM_COMPATIBLE), cString(info.name, PClassInfo::kNameSize).c_str(),
                    cString(info.category, PClassInfo::kCategorySize).c_str(), rawBytes(info.cid).c_str(),
                    canonicalId(info.cid).c_str(), static_cast<int32>(fuid.getLong1()), static_cast<int32>(fuid.getLong2()),
                    static_cast<int32>(fuid.getLong3()), static_cast<int32>(fuid.getLong4()));

        std::string kind = "other";
        if (std::strcmp(info.category, kVstAudioEffectClass) == 0)
            kind = "component";
        else if (std::strcmp(info.category, kVstComponentControllerClass) == 0)
            kind = "controller";
        if (got.count(kind) != 0)
        {
            std::printf("ERROR more than one %s class\n", kind.c_str());
            ok = false;
        }
        got[kind] = canonicalId(info.cid);

        // Hosts may read the ID through any of the three class-info calls, so all three must agree.
        PClassInfo2 info2{};
        if (factory2 == nullptr || factory2->getClassInfo2(i, &info2) != kResultOk)
        {
            std::printf("ERROR no getClassInfo2 for class %d\n", static_cast<int>(i));
            ok = false;
        }
        else if (std::memcmp(info2.cid, info.cid, sizeof(TUID)) != 0)
        {
            std::printf("ERROR getClassInfo2 gives class %d the ID %s\n", static_cast<int>(i), canonicalId(info2.cid).c_str());
            ok = false;
        }
        PClassInfoW infoW{};
        if (factory3 == nullptr || factory3->getClassInfoUnicode(i, &infoW) != kResultOk)
        {
            std::printf("ERROR no getClassInfoUnicode for class %d\n", static_cast<int>(i));
            ok = false;
        }
        else if (std::memcmp(infoW.cid, info.cid, sizeof(TUID)) != 0)
        {
            std::printf("ERROR getClassInfoUnicode gives class %d the ID %s\n", static_cast<int>(i),
                        canonicalId(infoW.cid).c_str());
            ok = false;
        }
    }
    if (factory2 != nullptr)
        factory2->release();
    if (factory3 != nullptr)
        factory3->release();

    if (count != 2 || got.count("other") != 0)
    {
        std::printf("ERROR expected exactly one component and one controller class, the factory lists %d classes\n",
                    static_cast<int>(count));
        ok = false;
    }
    for (const char* kind : {"component", "controller"})
    {
        const std::string want = expected[kind];
        const std::string have = got.count(kind) != 0 ? got[kind] : "(missing)";
        const bool same = want == have;
        std::printf("ID %s: frozen %s, got %s: %s\n", kind, want.c_str(), have.c_str(), same ? "OK" : "DIFFERENT");
        ok = ok && same;
    }
    std::printf("ID the same bytes through getClassInfo, getClassInfo2 and getClassInfoUnicode: %s\n", ok ? "yes" : "see errors");

    detail = "component " + (got.count("component") != 0 ? got["component"] : std::string("(missing)")) +
             ", controller " + (got.count("controller") != 0 ? got["controller"] : std::string("(missing)"));
    if (!ok)
        detail += " (frozen: component " + expected["component"] + ", controller " + expected["controller"] + ")";
    return ok;
}

// Hosts may call the exit function and later enter the module again without the library being unloaded in between
// (the VST3 SDK's own hosting code calls bundleExit but never CFBundleUnloadExecutable), so the plugin's static data
// survives. The IDs must come out the same the second time.
static bool checkIdsAgain(Module& module, const std::string& bundle, const std::string& build,
                          const std::string& frozenPath, std::string& detail)
{
    const std::string first = detail;
    module.unload();
    std::printf("--- again, after the exit function and a second entry (the library stays loaded)\n");
    if (!module.load(bundle))
    {
        detail = "could not enter " + bundle + " a second time";
        return false;
    }
    std::string again;
    if (!checkIds(module, build, frozenPath, again) || again != first)
    {
        detail = "after a second module entry: " + again;
        return false;
    }
    detail = first + ", the same after a second module entry";
    return true;
}

// --------------------------------------------------------------------------------------------------------------------
// Check: parameters

static bool checkParams(Module& module, const std::string& frozenPath, const std::string& writePath,
                        std::string& detail)
{
    setHostContext(module.factory);
    Session session;
    if (!session.open(module.factory, findClasses(module.factory)))
    {
        session.printSteps("STEP ");
        session.close();
        detail = "could not open the plugin: " + session.error;
        return false;
    }

    std::vector<Parameter> parameters;
    std::string error;
    bool ok = listParameters(session.controller, parameters, error);
    if (ok)
        ok = mapSymbols(session, parameters, error);
    session.close();
    if (!session.ok)
    {
        session.printSteps("STEP ");
        ok = false;
        if (error.empty())
            error = session.error;
    }

    const std::string json = parametersJson(parameters);
    std::printf("%s", json.c_str());
    if (!writePath.empty() && !writeFile(writePath, json))
        std::printf("ERROR could not write %s\n", writePath.c_str());
    if (!ok)
    {
        detail = error;
        return false;
    }
    return matchesFrozen(frozenPath, json, detail);
}

// --------------------------------------------------------------------------------------------------------------------
// Check: states

// The controller shows every saved value under the parameter the symbol belongs to.
static bool controllerShows(IEditController* controller, const std::vector<Parameter>& parameters,
                            const std::string& state, std::string& error)
{
    std::vector<StateValue> values;
    if (!stateParameters(splitState(state), values))
    {
        error = "no parameter section";
        return false;
    }
    bool ok = true;
    for (const StateValue& v : values)
    {
        const Parameter* p = nullptr;
        for (const Parameter& candidate : parameters)
            if (candidate.symbol == v.symbol)
                p = &candidate;
        if (p == nullptr)
        {
            error += (error.empty() ? "" : "; ") + ("no parameter is saved as " + v.symbol);
            ok = false;
            continue;
        }
        // DPF reads integer parameters (they have steps) with atoi and the others with atof into a float.
        const double want = p->info.stepCount > 0 ? static_cast<double>(std::atoi(v.value.c_str()))
                                                  : static_cast<double>(static_cast<float>(std::atof(v.value.c_str())));
        const double have = plainValue(controller, p->info.id);
        if (!sameValue(have, want))
        {
            char text[200];
            std::snprintf(text, sizeof(text), "%s (ID %u) shows %.9g instead of %.9g", v.symbol.c_str(),
                          static_cast<unsigned>(p->info.id), have, want);
            error += (error.empty() ? "" : "; ") + std::string(text);
            ok = false;
        }
    }
    return ok;
}

// Loads one state the way a host restores a saved project and checks what comes back.
static bool loadAndCompare(Session& session, const std::vector<Parameter>& parameters, const std::string& name,
                           const std::string& state, const char* how)
{
    bool ok = true;
    tresult result = loadComponentState(session.component, state);
    if (result != kResultOk)
    {
        std::printf("STATE %s (%s): component setState returned %s\n", name.c_str(), how, resultName(result));
        ok = false;
    }
    result = loadControllerState(session.controller, state);
    if (result != kResultOk)
    {
        std::printf("STATE %s (%s): controller setComponentState returned %s\n", name.c_str(), how, resultName(result));
        ok = false;
    }

    std::string saved;
    result = saveComponentState(session.component, saved);
    if (result != kResultOk)
    {
        std::printf("STATE %s (%s): getState returned %s\n", name.c_str(), how, resultName(result));
        ok = false;
    }
    else if (saved != state)
    {
        std::printf("STATE %s (%s): saved back DIFFERENT\n", name.c_str(), how);
        printStateDifference(state, saved);
        ok = false;
    }
    else
    {
        std::printf("STATE %s (%s): %zu bytes saved back byte for byte\n", name.c_str(), how, saved.size());
    }

    std::string error;
    if (controllerShows(session.controller, parameters, state, error))
        std::printf("STATE %s (%s): the controller shows every value under the right ID\n", name.c_str(), how);
    else
    {
        std::printf("STATE %s (%s): controller values WRONG: %s\n", name.c_str(), how, error.c_str());
        ok = false;
    }
    return ok;
}

static bool checkStates(Module& module, const std::vector<std::string>& files, std::string& detail)
{
    std::vector<std::pair<std::string, std::string>> states;
    for (const std::string& path : files)
    {
        std::string data;
        if (!readFile(path, data))
        {
            detail = "could not read " + path;
            return false;
        }
        states.push_back(std::make_pair(baseName(path), data));
    }
    if (states.empty())
    {
        detail = "no state files given";
        return false;
    }

    setHostContext(module.factory);
    const ClassIds ids = findClasses(module.factory);

    // Which parameter each symbol belongs to, measured once on its own instance.
    std::vector<Parameter> parameters;
    {
        Session probe;
        std::string error;
        bool ok = probe.open(module.factory, ids);
        if (ok)
            ok = listParameters(probe.controller, parameters, error) && mapSymbols(probe, parameters, error);
        probe.close();
        if (!ok || !probe.ok)
        {
            probe.printSteps("STEP ");
            detail = "could not map the saved symbols to parameters: " + (error.empty() ? probe.error : error);
            return false;
        }
    }

    bool ok = true;
    int failed = 0;

    // Each state into its own fresh instance, as when a saved project opens.
    for (const auto& state : states)
    {
        Session session;
        if (!session.open(module.factory, ids))
        {
            session.printSteps("STEP ");
            session.close();
            detail = "could not open the plugin: " + session.error;
            return false;
        }
        bool stateOk = true;
        if (state.first == "default.vst3state")
        {
            std::string fresh;
            const tresult result = saveComponentState(session.component, fresh);
            if (result == kResultOk && fresh == state.second)
            {
                std::printf("STATE a fresh instance saves exactly %s (%zu bytes)\n", state.first.c_str(), fresh.size());
            }
            else
            {
                std::printf("STATE a fresh instance saves something other than %s (getState: %s)\n",
                            state.first.c_str(), resultName(result));
                printStateDifference(state.second, fresh);
                stateOk = false;
            }
        }
        stateOk = loadAndCompare(session, parameters, state.first, state.second, "fresh instance") && stateOk;
        session.close();
        if (!session.ok)
        {
            session.printSteps("STEP ");
            stateOk = false;
        }
        if (!stateOk)
        {
            ok = false;
            ++failed;
        }
    }

    // All of them again, one after another, in one instance, as when a host switches between presets.
    {
        Session session;
        if (!session.open(module.factory, ids))
        {
            session.printSteps("STEP ");
            session.close();
            detail = "could not open the plugin: " + session.error;
            return false;
        }
        for (const auto& state : states)
        {
            if (!loadAndCompare(session, parameters, state.first, state.second, "one instance, in sequence"))
            {
                ok = false;
                ++failed;
            }
        }
        session.close();
        if (!session.ok)
        {
            session.printSteps("STEP ");
            ok = false;
        }
    }

    detail = std::to_string(states.size()) + " states, " +
             (ok ? std::string("all load and save back byte for byte")
                 : std::to_string(failed) + " load(s) went wrong");
    return ok;
}

// --------------------------------------------------------------------------------------------------------------------
// Check: instance

static const char* mediaName(int32 media)
{
    return media == kAudio ? "audio" : media == kEvent ? "event" : "other";
}

static bool checkInstance(Module& module, const std::string& frozenPath, const std::string& writePath,
                          std::string& detail)
{
    IPluginFactory* factory = module.factory;
    std::string json = "{\n";
    json += "  \"format\": \"wolf-shaper ci/vst3_check plugin-info 1\",\n";

    // What the factory says about itself and its classes (IDs are left out: they're platform-specific, see ids).
    PFactoryInfo factoryInfo{};
    const tresult factoryResult = factory->getFactoryInfo(&factoryInfo);
    const int32 count = factory->countClasses();
    json += "  \"factory\": {\n";
    json += "    \"get_factory_info\": " + jsonString(resultName(factoryResult)) + ",\n";
    json += "    \"vendor\": " + jsonString(cString(factoryInfo.vendor, PFactoryInfo::kNameSize)) + ",\n";
    json += "    \"url\": " + jsonString(cString(factoryInfo.url, PFactoryInfo::kURLSize)) + ",\n";
    json += "    \"email\": " + jsonString(cString(factoryInfo.email, PFactoryInfo::kEmailSize)) + ",\n";
    json += "    \"flags\": " + jsonInt(factoryInfo.flags) + ",\n";
    json += "    \"class_count\": " + jsonInt(count) + ",\n";
    json += "    \"set_host_context\": " + jsonString(resultName(setHostContext(factory))) + "\n";
    json += "  },\n";

    IPluginFactory2* factory2 = nullptr;
    IPluginFactory3* factory3 = nullptr;
    if (factory->queryInterface(IPluginFactory2_iid, reinterpret_cast<void**>(&factory2)) != kResultOk)
        factory2 = nullptr;
    if (factory->queryInterface(IPluginFactory3_iid, reinterpret_cast<void**>(&factory3)) != kResultOk)
        factory3 = nullptr;
    json += "  \"classes\": [\n";
    for (int32 i = 0; i < count; ++i)
    {
        PClassInfo info{};
        PClassInfo2 info2{};
        PClassInfoW infoW{};
        const tresult r1 = factory->getClassInfo(i, &info);
        const tresult r2 = factory2 != nullptr ? factory2->getClassInfo2(i, &info2) : kNoInterface;
        const tresult r3 = factory3 != nullptr ? factory3->getClassInfoUnicode(i, &infoW) : kNoInterface;
        json += "    {\n";
        json += "      \"index\": " + jsonInt(i) + ",\n";
        json += "      \"get_class_info\": " + jsonString(resultName(r1)) + ",\n";
        json += "      \"category\": " + jsonString(cString(info.category, PClassInfo::kCategorySize)) + ",\n";
        json += "      \"name\": " + jsonString(cString(info.name, PClassInfo::kNameSize)) + ",\n";
        json += "      \"cardinality\": " + jsonInt(info.cardinality) + ",\n";
        json += "      \"class_info_2\": {\n";
        json += "        \"result\": " + jsonString(resultName(r2)) + ",\n";
        json += "        \"name\": " + jsonString(cString(info2.name, PClassInfo::kNameSize)) + ",\n";
        json += "        \"vendor\": " + jsonString(cString(info2.vendor, PClassInfo2::kVendorSize)) + ",\n";
        json += "        \"version\": " + jsonString(cString(info2.version, PClassInfo2::kVersionSize)) + ",\n";
        json += "        \"sdk_version\": " + jsonString(cString(info2.sdkVersion, PClassInfo2::kVersionSize)) + ",\n";
        json += "        \"sub_categories\": " +
                jsonString(cString(info2.subCategories, PClassInfo2::kSubCategoriesSize)) + ",\n";
        json += "        \"class_flags\": " + jsonInt(info2.classFlags) + "\n";
        json += "      },\n";
        json += "      \"class_info_unicode\": {\n";
        json += "        \"result\": " + jsonString(resultName(r3)) + ",\n";
        json += "        \"name\": " + jsonString(toUtf8(infoW.name, PClassInfo::kNameSize)) + ",\n";
        json += "        \"vendor\": " + jsonString(toUtf8(infoW.vendor, PClassInfoW::kVendorSize)) + ",\n";
        json += "        \"version\": " + jsonString(toUtf8(infoW.version, PClassInfoW::kVersionSize)) + ",\n";
        json += "        \"sdk_version\": " + jsonString(toUtf8(infoW.sdkVersion, PClassInfoW::kVersionSize)) + ",\n";
        json += "        \"sub_categories\": " +
                jsonString(cString(infoW.subCategories, PClassInfoW::kSubCategoriesSize)) + ",\n";
        json += "        \"class_flags\": " + jsonInt(infoW.classFlags) + "\n";
        json += "      }\n";
        json += std::string("    }") + (i + 1 < count ? "," : "") + "\n";
    }
    json += "  ],\n";
    if (factory2 != nullptr)
        factory2->release();
    if (factory3 != nullptr)
        factory3->release();

    // Open it the way a host does, step by step.
    const ClassIds ids = findClasses(factory);
    Session session;
    bool ok = session.open(factory, ids);
    std::printf("Opening the plugin:\n");
    session.printSteps("STEP ");
    if (!ok)
    {
        session.close();
        detail = "could not open the plugin: " + session.error;
        return false;
    }

    // What the component offers a host.
    IEditController* alsoController = nullptr;
    const tresult singleComponent =
        session.component->queryInterface(IEditController_iid, reinterpret_cast<void**>(&alsoController));
    if (singleComponent == kResultOk && alsoController != nullptr)
        alsoController->release();
    IAudioProcessor* processor = nullptr;
    const tresult hasProcessor =
        session.component->queryInterface(IAudioProcessor_iid, reinterpret_cast<void**>(&processor));
    if (hasProcessor != kResultOk)
        processor = nullptr;

    json += "  \"component\": {\n";
    json += "    \"also_edit_controller\": " + jsonString(resultName(singleComponent)) + ",\n";
    json += "    \"audio_processor\": " + jsonString(resultName(hasProcessor)) + ",\n";
    json += "    \"connection_point\": " + jsonString(session.componentPoint != nullptr ? "ok" : "no_interface") + ",\n";
    json += "    \"buses\": [\n";
    std::string buses;
    for (int32 media : {static_cast<int32>(kAudio), static_cast<int32>(kEvent)})
    {
        for (int32 direction : {static_cast<int32>(kInput), static_cast<int32>(kOutput)})
        {
            const int32 busCount = session.component->getBusCount(media, direction);
            for (int32 b = 0; b < busCount; ++b)
            {
                BusInfo bus{};
                const tresult r = session.component->getBusInfo(media, direction, b, bus);
                if (!buses.empty())
                    buses += ",\n";
                buses += "      {\"media\": " + jsonString(mediaName(media)) + ", \"direction\": " +
                         jsonString(direction == kInput ? "input" : "output") + ", \"index\": " + jsonInt(b) +
                         ", \"result\": " + jsonString(resultName(r)) + ", \"name\": " +
                         jsonString(toUtf8(bus.name, 128)) + ", \"channels\": " + jsonInt(bus.channelCount) +
                         ", \"type\": " + jsonString(bus.busType == kMain ? "main" : "aux") +
                         ", \"flags\": " + jsonInt(bus.flags) + "}";
            }
        }
    }
    json += buses + (buses.empty() ? "" : "\n") + "    ],\n";
    if (processor != nullptr)
    {
        SpeakerArrangement input = 0, output = 0;
        const tresult ri = processor->getBusArrangement(kInput, 0, input);
        const tresult ro = processor->getBusArrangement(kOutput, 0, output);
        json += "    \"bus_arrangement\": {\"input\": " + jsonInt(static_cast<long long>(input)) + ", \"input_result\": " +
                jsonString(resultName(ri)) + ", \"output\": " + jsonInt(static_cast<long long>(output)) +
                ", \"output_result\": " + jsonString(resultName(ro)) + "},\n";
        json += "    \"latency_samples\": " + jsonInt(processor->getLatencySamples()) + ",\n";
        json += "    \"tail_samples\": " + jsonInt(processor->getTailSamples()) + ",\n";
        json += "    \"can_process_32bit\": " + jsonString(resultName(processor->canProcessSampleSize(kSample32))) + ",\n";
        json += "    \"can_process_64bit\": " + jsonString(resultName(processor->canProcessSampleSize(kSample64))) + "\n";
        processor->release();
        processor = nullptr;
    }
    else
    {
        json += "    \"bus_arrangement\": null\n";
    }
    json += "  },\n";

    // What the controller offers a host. Hosts save the controller's getState next to the component's state (in
    // Ableton Live projects, <ControllerState>) and hand it back with setState when a project opens.
    MemoryStream controllerState;
    const tresult getStateResult = session.controller->getState(&controllerState);
    MemoryStream empty;
    const tresult setStateResult = session.controller->setState(&empty);
    json += "  \"controller\": {\n";
    json += "    \"connection_point\": " + jsonString(session.controllerPoint != nullptr ? "ok" : "no_interface") + ",\n";
    json += "    \"parameter_count\": " + jsonInt(session.controller->getParameterCount()) + ",\n";
    json += "    \"get_state\": {\"result\": " + jsonString(resultName(getStateResult)) +
            ", \"bytes\": " + jsonInt(static_cast<long long>(controllerState.data.size())) + "},\n";
    json += "    \"set_state_empty\": " + jsonString(resultName(setStateResult)) + "\n";
    json += "  }\n}\n";

    // A second instance while the first is open, as when a project uses Wolf Shaper on two tracks.
    {
        Session second;
        const bool secondOk = second.open(factory, ids);
        second.close();
        std::printf("Second instance alongside the first:\n");
        second.printSteps("STEP ");
        if (!secondOk || !second.ok)
        {
            ok = false;
            detail = "a second instance could not be opened: " + second.error;
        }
    }

    std::printf("Closing the plugin:\n");
    const size_t before = session.steps.size();
    session.close();
    for (size_t i = before; i < session.steps.size(); ++i)
        std::printf("STEP %s\n", session.steps[i].c_str());
    if (!session.ok)
    {
        ok = false;
        if (detail.empty())
            detail = session.error;
    }

    std::printf("%s", json.c_str());
    if (!writePath.empty() && !writeFile(writePath, json))
        std::printf("ERROR could not write %s\n", writePath.c_str());
    if (!ok)
        return false;
    return matchesFrozen(frozenPath, json, detail);
}

// --------------------------------------------------------------------------------------------------------------------

static int usage()
{
    std::printf("usage:\n"
                "  vst3_check ids <bundle> <ours|official> <class-ids.txt>\n"
                "  vst3_check params <bundle> <parameters.json> [<write to>]\n"
                "  vst3_check states <bundle> <state file>...\n"
                "  vst3_check instance <bundle> <plugin-info.json> [<write to>]\n");
    return 2;
}

int main(int argc, char* argv[])
{
    if (argc < 4)
        return usage();
    const std::string check = argv[1];
    const std::string bundle = argv[2];
    if (check != "ids" && check != "params" && check != "states" && check != "instance")
        return usage();
    if (check == "ids" && argc != 5)
        return usage();
    if ((check == "params" || check == "instance") && argc > 5)
        return usage();

    std::printf("vst3_check %s on %s (%s %s)\n", check.c_str(), bundle.c_str(), CHECK_OS, CHECK_CPU);
    std::fflush(stdout);

    Module module;
    bool pass = false;
    std::string detail;
    if (!module.load(bundle))
    {
        detail = "could not load " + bundle;
    }
    else
    {
        if (check == "ids")
            pass = checkIds(module, argv[3], argv[4], detail) && checkIdsAgain(module, bundle, argv[3], argv[4], detail);
        else if (check == "params")
            pass = checkParams(module, argv[3], argc > 4 ? argv[4] : "", detail);
        else if (check == "states")
            pass = checkStates(module, std::vector<std::string>(argv + 3, argv + argc), detail);
        else
            pass = checkInstance(module, argv[3], argc > 4 ? argv[4] : "", detail);
        std::fflush(stdout);
        module.unload();
    }

    std::printf("RESULT %s %s %s\n", check.c_str(), pass ? "PASS" : "FAIL", detail.c_str());
    std::fflush(stdout);
    return pass ? 0 : 1;
}
