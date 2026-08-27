# bench-cam

A camera you can call from a script, so a change to a screen can be checked by looking at
the screen instead of asking a human what happened.

    ./build.sh
    open -a ./bench-cam.app --args shot.jpg --crop 700,180,720,800   # headless
    open -a ./bench-cam.app --args shot.jpg --preview                # window with a shutter
    ./levels.py shot.jpg                                             # is it worth opening?
    ./shoot.sh "screen sliders" shot.jpg                             # drive the board, then shoot

## Things that cost hours to learn

**It has to be an app bundle.** TCC grants camera access to bundle identifiers. A
command-line tool has no identity to grant, which is why `imagesnap` and friends are
refused before their request ever reaches the permission list.

**It has to be launched through LaunchServices.** `open -a ...`, not by running the binary.
TCC attributes a request to the *responsible process*, and a binary run from a shell is
attributed to the terminal, so the grant does not apply.

**LaunchServices discards stderr.** The mechanism that makes the grant work is the one
that hides why it did not. Failures go to `<output>.err`; to watch live use
`open -W --stdout f --stderr f -a ...`.

**Ad-hoc signing loses the camera grant on every rebuild.** With no signing identity the
designated requirement is nothing but the code hash — the bundle identifier does not
appear in it — so each build is a different app to TCC. It then wants to re-prompt, an
LSUIElement bundle cannot present that prompt, and the process hangs for a minute and
dies. `./make-signing-cert.sh` fixes it permanently; without it, expect one
re-authorisation per rebuild, and rebuild sparingly.

**macOS has no manual exposure.** Exposure duration, ISO and exposure target bias are
iOS-only on AVCaptureDevice, and locked white balance is unavailable outright. A UVC
camera here can be told to hold the exposure it already chose and nothing more. The fix
for a blown-out photograph of a screen is the lamp, which is what the preview's clipping
meter is for.

**macOS has no PTZ.** There is no way to aim, wake or move a motorised camera from here:
AVFoundation exposes no pan/tilt for external cameras, and reaching the UVC controls
directly means claiming an interface the system's own video driver owns. A camera that
sleeps head-down behind a shutter has to be woken by hand or by its vendor's app.

**Warm-up in frames is the wrong unit for a camera that moves.** A gimballed camera
delivers frames throughout its wake, so ninety frames can all be pictures of the inside of
a shutter. `--settle SECONDS` waits in wall-clock time instead.

## levels.py

An unlit room, a shuttered lens, a bad exposure and a good photograph of a small bright
thing all render as a black rectangle. Their pixel statistics do not:

- exact zeros everywhere — the camera is asleep or shuttered
- a floor of ones and twos with a peak of three — sensor noise, nothing in frame is lit
- a low mean with a high peak — a lit subject on a dark ground, which is usually correct

Judging on the peak rather than the mean matters: a good photograph of a watch face
averages about 2, and the first version called it DARK.
