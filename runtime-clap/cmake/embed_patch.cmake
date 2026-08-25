# Embeds a file as a byte array header. Bytes rather than a string literal so no
# escaping rule can ever corrupt the content; a trailing NUL so it reads back as a
# C string.
#
#   cmake -DINPUT=<file> -DOUTPUT=<header.h> [-DSYMBOL=<name>] -P embed_patch.cmake

if(NOT DEFINED SYMBOL)
    set(SYMBOL kDefaultPatch)
endif()

file(READ ${INPUT} content HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes ${content})
file(WRITE ${OUTPUT} "// Generated from ${INPUT} by embed_patch.cmake. Do not edit.
#pragma once

namespace soundgraph_clap {
inline const unsigned char ${SYMBOL}[] = {${bytes}0x00};
}  // namespace soundgraph_clap
")
