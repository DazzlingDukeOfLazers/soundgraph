// SoundGraph — the three functions a CLAP entry point needs, exported from the static
// implementation library so that clap-wrapper can assemble every plugin format around
// the same implementation.
#pragma once

extern bool soundgraph_clap_init(const char* plugin_path);
extern void soundgraph_clap_deinit();
extern const void* soundgraph_clap_get_factory(const char* factory_id);
