// Speech analysis for the Speech node: samples in, TMS5220-style bitstream out.
//
// The editor half of the speak pipeline — the node speaks buffers, this writes
// them. Offline by nature: call it from tools and editors, never from process().

#pragma once

#include <vector>

namespace soundgraph {

// Encodes mono samples at any rate into the Speech node's bitstream: LPC-10
// frames quantized to the TMS5220 coefficient ROM, LSB-first bytes, stop frame
// included. Empty or nonsense input yields a lone stop frame rather than a crash.
std::vector<unsigned char> encode_lpc(const float* samples, int count,
                                      double sample_rate);

}  // namespace soundgraph
