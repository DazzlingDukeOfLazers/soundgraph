// miniaudio's single translation unit.
//
// Kept on its own so that the rest of the native host can be built with the project's
// warning settings without drowning in third-party noise.
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_ENCODING
#define MA_NO_DECODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#include "miniaudio.h"
