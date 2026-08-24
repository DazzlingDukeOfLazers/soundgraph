// SoundGraph — the exported CLAP entry. Recompiled once per plugin format by
// clap-wrapper; everything real lives in the static library behind these three names.
#include <clap/clap.h>

#include "soundgraph_clap_entry.h"

extern "C" {
#ifdef __GNUC__
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wattributes"
#endif

const CLAP_EXPORT struct clap_plugin_entry clap_entry = {
    CLAP_VERSION, soundgraph_clap_init, soundgraph_clap_deinit, soundgraph_clap_get_factory};

#ifdef __GNUC__
#pragma GCC diagnostic pop
#endif
}
