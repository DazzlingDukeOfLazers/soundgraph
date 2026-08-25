"""Tier 6: MIDI, on all three transports the board owns.

- USB device port: the Axoloti is a class-compliant USB-MIDI device on the
  same cable that carries the test protocol, so the Mac's CoreMIDI drives it
  directly (mido + python-rtmidi) — no extra hardware.
- DIN in/out: one male-male 5-pin DIN cable looped out->in. The patch
  transmits deterministic bursts and counts/checksums what returns. These
  tests skip until the cable is detected.
- USB host port: needs a class-compliant controller plugged into the A port;
  the receive counter test skips until one has sent something.

The stresslab patch counts every received message per transport, keeps a
rolling checksum, and can echo or transmit bursts. Bursts execute in the
firmware's MIDI input thread on a CC-119/ch-16 trigger — the transports'
blocking writes (DIN is 31250 baud) are backpressure there, never an audio
dropout; the firmware's buffer-headroom query is a stub for these transports.
"""

import time

import pytest

import shm
from conftest import load_patch_bin

try:
    import mido
except ImportError:
    mido = None

BOARD_PORT_HINT = "Axoloti"


def _mido_port_name(direction):
    names = (mido.get_output_names() if direction == "out"
             else mido.get_input_names())
    for name in names:
        if BOARD_PORT_HINT.lower() in name.lower():
            return name
    return None


@pytest.fixture(scope="module")
def stresslab(board):
    board.run_patch(load_patch_bin("stresslab"), expect_patch_id=shm.STRESSLAB_ID)
    yield board
    try:
        shm.set_midi_echo(board, 0)
        board.stop_patch()
    except Exception:
        pass


@pytest.fixture()
def midi_out(stresslab):
    if mido is None:
        pytest.skip("mido/python-rtmidi not installed")
    name = _mido_port_name("out")
    if name is None:
        pytest.skip("no CoreMIDI port matching 'Axoloti' — USB MIDI absent?")
    port = mido.open_output(name)
    yield port
    port.close()


@pytest.fixture()
def midi_in(stresslab):
    if mido is None:
        pytest.skip("mido/python-rtmidi not installed")
    name = _mido_port_name("in")
    if name is None:
        pytest.skip("no CoreMIDI port matching 'Axoloti' — USB MIDI absent?")
    port = mido.open_input(name)
    yield port
    port.close()


def _wait_count(board, getter, target, timeout_s=5.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        n = getter(shm.read_shm(board))
        if n >= target:
            return n
        time.sleep(0.05)
    return getter(shm.read_shm(board))


# --- USB device port (no extra hardware) ------------------------------------

def test_usb_device_midi_receive(stresslab, midi_out):
    """Mac -> board: 200 messages arrive complete and byte-exact."""
    board = stresslab
    shm.clear_midi_counters(board)
    sent = []
    for i in range(200):
        b0, b1, b2 = 0x90, (i * 5) % 128, ((i * 11) % 127) + 1
        midi_out.send(mido.Message("note_on", note=b1, velocity=b2))
        sent.append((b0, b1, b2))
    got = _wait_count(board, lambda s: s.cum_midi_usbd, 200)
    state = shm.read_shm(board)
    assert got == 200, f"board received {got}/200 messages"
    expected = shm.midi_checksum(sent, shm.MIDI_DEV_USB_DEVICE)
    assert state.midi_checksum == expected, (
        f"checksum {state.midi_checksum:#010x} != {expected:#010x} — "
        "bytes corrupted or reordered")


def _trigger_burst(board, midi_out, device, count):
    """Program a burst and fire it with the CC-119-on-channel-16 trigger.
    The patch executes the burst synchronously in the MIDI input thread,
    where the transports' blocking writes are backpressure, not dropouts."""
    shm.start_midi_burst(board, device, count)
    midi_out.send(mido.Message("control_change", channel=15, control=119,
                               value=0))


def test_usb_device_midi_transmit(stresslab, midi_out, midi_in):
    """Board -> Mac: a 100-message burst arrives in order, byte-exact."""
    board = stresslab
    while midi_in.poll():  # flush stale
        pass
    _trigger_burst(board, midi_out, shm.MIDI_DEV_USB_DEVICE, 100)
    received = []
    deadline = time.monotonic() + 5.0
    while len(received) < 100 and time.monotonic() < deadline:
        msg = midi_in.poll()
        if msg is None:
            time.sleep(0.01)
            continue
        if msg.type == "note_on":
            received.append((0x90, msg.note, msg.velocity))
    assert len(received) == 100, f"got {len(received)}/100"
    for i, msg in enumerate(received):
        assert msg == shm.burst_message(i), f"message {i}: {msg}"


def test_usb_device_midi_echo_latency(stresslab, midi_out, midi_in):
    """Mac -> board -> Mac round trip: complete, ordered, and quick."""
    board = stresslab
    shm.set_midi_echo(board, 1 << shm.MIDI_DEV_USB_DEVICE)
    while midi_in.poll():
        pass
    latencies = []
    try:
        for i in range(50):
            note, vel = (i * 3) % 128, ((i * 7) % 127) + 1
            t0 = time.monotonic()
            midi_out.send(mido.Message("note_on", note=note, velocity=vel))
            deadline = t0 + 1.0
            while time.monotonic() < deadline:
                msg = midi_in.poll()
                if msg is not None and msg.type == "note_on":
                    assert (msg.note, msg.velocity) == (note, vel), f"echo {i}"
                    latencies.append(time.monotonic() - t0)
                    break
            else:
                pytest.fail(f"echo {i} never returned")
    finally:
        shm.set_midi_echo(board, 0)
    latencies.sort()
    median = latencies[len(latencies) // 2]
    worst = latencies[-1]
    print(f"\nUSB MIDI echo: median {median * 1000:.1f} ms, "
          f"worst {worst * 1000:.1f} ms over 50 round trips")
    assert median < 0.020
    assert worst < 0.100


def test_usb_device_midi_receive_under_load(stresslab, midi_out):
    """MIDI must not drop while the DSP runs at ~84%."""
    board = stresslab
    shm.set_nosc(board, 160)
    time.sleep(0.3)
    shm.clear_midi_counters(board)
    for i in range(200):
        midi_out.send(mido.Message("note_on", note=(i % 127) + 1, velocity=64))
    got = _wait_count(board, lambda s: s.cum_midi_usbd, 200)
    shm.set_nosc(board, 0)
    assert got == 200, f"dropped {200 - got} of 200 MIDI messages at 84% load"


# --- DIN in/out (needs one male-male 5-pin DIN loopback cable) ---------------

def _din_loopback_present(board, midi_out):
    shm.clear_midi_counters(board)
    _trigger_burst(board, midi_out, shm.MIDI_DEV_DIN, 5)
    n = _wait_count(board, lambda s: s.cum_midi_din, 5, timeout_s=1.5)
    return n >= 5


def test_din_midi_loopback_integrity(stresslab, midi_out):
    board = stresslab
    if not _din_loopback_present(board, midi_out):
        pytest.skip("no DIN loopback detected — connect MIDI OUT to MIDI IN "
                    "with a 5-pin DIN cable")
    shm.clear_midi_counters(board)
    _trigger_burst(board, midi_out, shm.MIDI_DEV_DIN, 500)
    t0 = time.monotonic()
    got = _wait_count(board, lambda s: s.cum_midi_din, 500, timeout_s=10.0)
    elapsed = time.monotonic() - t0
    state = shm.read_shm(board)
    assert got == 500, f"DIN loopback returned {got}/500"
    expected = shm.midi_checksum(
        [shm.burst_message(i) for i in range(500)], shm.MIDI_DEV_DIN)
    assert state.midi_checksum == expected, "DIN bytes corrupted"
    rate = 500 / elapsed
    print(f"\nDIN loopback: 500 messages in {elapsed:.2f} s ({rate:.0f} msg/s; "
          "31250 baud tops out ~1040)")
    assert rate > 700, "DIN throughput far below wire speed"


def test_din_midi_loopback_under_load(stresslab, midi_out):
    board = stresslab
    if not _din_loopback_present(board, midi_out):
        pytest.skip("no DIN loopback detected")
    shm.set_nosc(board, 160)
    time.sleep(0.3)
    shm.clear_midi_counters(board)
    _trigger_burst(board, midi_out, shm.MIDI_DEV_DIN, 300)
    got = _wait_count(board, lambda s: s.cum_midi_din, 300, timeout_s=10.0)
    shm.set_nosc(board, 0)
    assert got == 300, f"DIN dropped {300 - got}/300 at 84% DSP load"


# --- USB host port (needs a class-compliant device on the A port) ------------

def test_usb_host_midi_receive(stresslab):
    """Passive: skips until a controller on the USB host port has sent
    something (press a key/knob on the attached device during the run, or use
    a programmable device that sends on its own)."""
    board = stresslab
    n = shm.read_shm(board).cum_midi_usbh
    if n == 0:
        pytest.skip("nothing received on the USB host port — attach a "
                    "class-compliant MIDI device and make it send")
    print(f"\nUSB host port has received {n} MIDI messages")
