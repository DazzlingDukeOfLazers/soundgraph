// GDExtension entry point.
#include <gdextension_interface.h>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "soundgraph_engine.h"

using namespace godot;

void initialize_soundgraph_module(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(soundgraph_godot::SoundGraphEngine);
}

void uninitialize_soundgraph_module(ModuleInitializationLevel level) {
    (void)level;
}

extern "C" {

GDExtensionBool GDE_EXPORT soundgraph_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                                   const GDExtensionClassLibraryPtr library,
                                                   GDExtensionInitialization* initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_soundgraph_module);
    init.register_terminator(uninitialize_soundgraph_module);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}

}  // extern "C"
