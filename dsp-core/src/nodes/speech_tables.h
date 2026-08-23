// The TMS5220's coefficient ROM, shared by the voice and the encoder.
//
// Decap-verified constants (TMS5220NL, imaged by digshadow in April 2013, as
// recorded in MAME's tms5110r reference; published hardware facts). One header,
// two readers: speech.cpp speaks these tables, lpc_encoder.cpp quantizes to them,
// and a drifted copy would be a voice that cannot say what the encoder wrote.
// tools/lpc-encode.mjs carries the deliberate third copy, for encoding without a
// native build — if it ever disagrees with this file, one of them was vandalised.

#pragma once

namespace soundgraph {
namespace nodes {

// ---------------------------------------------------------------------------------
// The TMS5220 coefficient ROM.
// ---------------------------------------------------------------------------------

constexpr float kSpeechEnergy[16] = {0, 1, 2, 3, 4, 6, 8, 11, 16, 23, 33, 47, 63, 85, 114, 0};

constexpr int kSpeechPitch[64] = {
    0,   15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,
    30,  31,  32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  44,  46,  48,
    50,  52,  53,  56,  58,  60,  62,  65,  68,  70,  72,  76,  78,  80,  84,  86,
    91,  94,  98,  101, 105, 109, 114, 118, 122, 127, 132, 137, 142, 148, 153, 159};

constexpr int kSpeechK1[32] = {
    -501, -498, -497, -495, -493, -491, -488, -482, -478, -474, -469, -464, -459, -452,
    -445, -437, -412, -380, -339, -288, -227, -158, -81,  -1,   80,   157,  226,  287,
    337,  379,  411,  436};
constexpr int kSpeechK2[32] = {
    -328, -303, -274, -244, -211, -175, -138, -99, -59, -18, 24,  64,  105, 143,
    180,  215,  248,  278,  306,  331,  354,  374, 392, 408, 422, 435, 445, 455,
    463,  470,  476,  506};
constexpr int kSpeechK3[16] = {-441, -387, -333, -279, -225, -171, -117, -63,
                               -9,   45,   98,   152,  206,  260,  314,  368};
constexpr int kSpeechK4[16] = {-328, -273, -217, -161, -106, -50,  5,    61,
                               116,  172,  228,  283,  339,  394,  450,  506};
constexpr int kSpeechK5[16] = {-328, -282, -235, -189, -142, -96,  -50,  -3,
                               43,   90,   136,  182,  229,  275,  322,  368};
constexpr int kSpeechK6[16] = {-256, -212, -168, -123, -79,  -35,  10,   54,
                               98,   143,  187,  232,  276,  320,  365,  409};
constexpr int kSpeechK7[16] = {-308, -260, -212, -164, -117, -69,  -21,  27,
                               75,   122,  170,  218,  266,  314,  361,  409};
constexpr int kSpeechK8[8] = {-256, -161, -66, 29, 124, 219, 314, 409};
constexpr int kSpeechK9[8] = {-256, -176, -96, -15, 65, 146, 226, 307};
constexpr int kSpeechK10[8] = {-205, -132, -59, 14, 87, 160, 234, 307};

constexpr const int* kSpeechKTables[10] = {
    kSpeechK1, kSpeechK2, kSpeechK3, kSpeechK4, kSpeechK5,
    kSpeechK6, kSpeechK7, kSpeechK8, kSpeechK9, kSpeechK10};
constexpr int kSpeechKBits[10] = {5, 5, 4, 4, 4, 4, 4, 3, 3, 3};

// The voiced excitation: one glottal chirp, replayed every pitch period.
constexpr int kSpeechChirp[52] = {
    0x00, 0x03, 0x0f, 0x28, 0x4c, 0x6c, 0x71, 0x50, 0x25, 0x26, 0x4c, 0x44, 0x1a,
    0x32, 0x3b, 0x13, 0x37, 0x1a, 0x25, 0x1f, 0x1d, 0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0};

// The interpolation ladder: how much of the gap to the next frame's parameters is
// closed at each of the eight sub-frame boundaries, ending on the target exactly.
constexpr float kSpeechGlide[8] = {0.125f, 0.125f, 0.125f, 0.25f, 0.25f, 0.5f, 0.5f, 1.0f};

constexpr int kSpeechRate = 8000;
constexpr int kSpeechFrame = 200;   // 25 ms
constexpr int kSpeechPeriodLength = kSpeechFrame / 8;

}  // namespace nodes
}  // namespace soundgraph
