// sfxr parameters -> a SoundGraph patch. See to_patch.cpp for every conversion and its
// derivation.
#ifndef SOUNDGRAPH_SFXR_TO_PATCH_H
#define SOUNDGRAPH_SFXR_TO_PATCH_H

#include <string>

#include "sfxr_reference.h"

namespace sfxr_map {

// Returns the patch as JSON text, ready to hand to sg-render.
std::string to_patch(const sfxr_reference::Params& params, const std::string& name);

}  // namespace sfxr_map

#endif
