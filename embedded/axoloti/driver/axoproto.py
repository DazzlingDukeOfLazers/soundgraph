"""Host-side driver for the Axoloti Core vendor USB protocol.

Speaks the bulk protocol of firmware 1.0.12-2 (the last stock release).
Protocol reference: firmware/pconnection.c at tag 1.0.12-2 of
https://github.com/axoloti/axoloti — the command set is four ASCII bytes
"Axo" + one command character, followed by little-endian arguments.

The firmware only parses host input while no acknowledge is pending, so this
driver is strictly request/response: send one command, collect its replies,
then send the next.
"""

import struct
import time
from collections import deque
from dataclasses import dataclass

import usb.core
import usb.util
import usb.backend.libusb1

VID = 0x16C0
PID = 0x0442
INTERFACE = 2
EP_OUT = 0x02
EP_IN = 0x82

# Reported by "AxoV" and hardcoded in firmware patch.h; patches are uploaded here.
PATCHMAINLOC = 0x20011000
# Code + rodata window of a patch binary (ramlink.ld SRAM region), in bytes.
PATCH_CODE_SIZE = 0xB000
# Second patch RAM region (ramlink.ld SRAM2); our test patches place their
# host-visible shared-memory block at its start.
SRAM2LOC = 0x2001C000

# CRC32 of the stock 1.0.12-2 release firmware flash image. Patch binaries in
# patches/ are linked against exactly this build; a board reporting a different
# fwid needs different link symbols (see README).
STOCK_1_0_12_2_FWID = 0xE95BAC96

_LIBUSB_CANDIDATES = (
    None,  # let pyusb search default paths first
    "/opt/homebrew/lib/libusb-1.0.dylib",
    "/usr/local/lib/libusb-1.0.dylib",
)


@dataclass
class Ack:
    dsp_load: int      # percent
    patch_id: int
    voltage_10: int    # sysmon 1.0V rail reading (raw)
    voltage_50: int    # sysmon 5.0V rail reading (raw)
    patch_index: int   # loadPatchIndex, or UNINITIALIZED(-5) while a patch runs
    fs_ready: int      # SD card filesystem mounted


@dataclass
class FwInfo:
    version: tuple     # (major, minor, x, y)
    fwid: int          # CRC32 of the board's firmware flash image
    patchmainloc: int


class ProtocolError(RuntimeError):
    pass


class BoardNotFound(RuntimeError):
    pass


def _backend():
    for path in _LIBUSB_CANDIDATES:
        if path is None:
            be = usb.backend.libusb1.get_backend()
        else:
            be = usb.backend.libusb1.get_backend(find_library=lambda x, p=path: p)
        if be is not None:
            return be
    raise BoardNotFound("libusb-1.0 not found (brew install libusb)")


class Axoloti:
    """One claimed connection to an Axoloti Core."""

    def __init__(self):
        self.log_messages = deque(maxlen=64)  # collected "AxoT" text messages
        try:
            self._connect()
        except (ProtocolError, usb.core.USBError):
            # A prior session that died unreleased can leave the pipe in a
            # state where transfers fail outright (libusb -99). A device
            # reset re-enumerates and clears it; the firmware keeps running.
            self._reset_device()
            self._connect()

    def _reset_device(self):
        dev = usb.core.find(idVendor=VID, idProduct=PID, backend=_backend())
        if dev is None:
            raise BoardNotFound("no Axoloti Core (16c0:0442) on USB")
        try:
            dev.reset()
        except usb.core.USBError:
            pass  # reset drops the handle; that's the point
        usb.util.dispose_resources(dev)
        time.sleep(2.0)

    def _connect(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID, backend=_backend())
        if self.dev is None:
            raise BoardNotFound("no Axoloti Core (16c0:0442) on USB")
        usb.util.claim_interface(self.dev, INTERFACE)
        self._rx = b""
        # A prior session may have died mid-stream: drain leftovers and prove
        # the link with a ping before handing out the connection.
        last_error = None
        for _ in range(3):
            self.drain()
            try:
                self.ping(timeout_s=1.0)
                return
            except ProtocolError as e:
                last_error = e
        usb.util.release_interface(self.dev, INTERFACE)
        usb.util.dispose_resources(self.dev)
        raise ProtocolError(f"board unresponsive after resync: {last_error}")

    def close(self):
        usb.util.release_interface(self.dev, INTERFACE)
        usb.util.dispose_resources(self.dev)

    # --- raw stream handling -------------------------------------------------

    def _read_some(self, timeout_ms):
        try:
            return bytes(self.dev.read(EP_IN, 4096, timeout=timeout_ms))
        except usb.core.USBTimeoutError:
            return b""

    def drain(self, settle_ms=150):
        """Discard buffered board->host traffic (acks from prior sessions etc.)."""
        while self._read_some(settle_ms):
            pass
        self._rx = b""

    def _parse_one(self):
        """Try to pop one complete packet from the receive buffer.

        Returns (kind, payload) or None if more bytes are needed.
        """
        buf = self._rx
        # Resynchronize on "Axo" if the stream is misaligned. Keep the last
        # two bytes: the board fragments packets arbitrarily, so a header may
        # arrive as ... 'A' | 'xo...' across bulk transfers.
        start = buf.find(b"Axo")
        if start < 0:
            self._rx = buf[-2:]
            return None
        if start > 0:
            buf = self._rx = buf[start:]
        if len(buf) < 4:
            return None
        kind = chr(buf[3])
        if kind == "A":                      # periodic/command acknowledge
            if len(buf) < 28:
                return None
            fields = struct.unpack("<6i", buf[4:28])
            self._rx = buf[28:]
            return "A", self._ack_from(fields)
        if kind == "V":                      # firmware version reply
            if len(buf) < 16:
                return None
            payload = buf[4:16]
            self._rx = buf[16:]
            return "V", payload
        if kind == "r":                      # memory read reply
            if len(buf) < 12:
                return None
            addr, length = struct.unpack("<II", buf[4:12])
            if len(buf) < 12 + length:
                return None
            data = buf[12:12 + length]
            self._rx = buf[12 + length:]
            return "r", (addr, data)
        if kind == "y":                      # single word read reply
            if len(buf) < 12:
                return None
            addr, value = struct.unpack("<II", buf[4:12])
            self._rx = buf[12:]
            return "y", (addr, value)
        if kind == "T":                      # LogTextMessage, NUL-terminated
            end = buf.find(b"\x00", 4)
            if end < 0:
                return None
            text = buf[4:end].decode("ascii", errors="replace")
            self._rx = buf[end + 1:]
            return "T", text
        if kind == "Q":                      # parameter change push
            if len(buf) < 16:
                return None
            payload = struct.unpack("<3i", buf[4:16])
            self._rx = buf[16:]
            return "Q", payload
        if kind == "d":                      # SD filesystem stats header
            if len(buf) < 16:
                return None
            clusters, csize, bsize = struct.unpack("<III", buf[4:16])
            self._rx = buf[16:]
            return "d", (clusters, csize, bsize)
        if kind == "f":                      # SD file/dir entry, NUL-terminated
            if len(buf) < 12:
                return None
            end = buf.find(b"\x00", 12)
            if end < 0:
                return None
            size, stamp = struct.unpack("<iI", buf[4:12])
            name = buf[12:end].decode("ascii", errors="replace")
            self._rx = buf[end + 1:]
            return "f", (name, size, stamp)
        # Unknown/unexpected kind: drop the header and resync.
        self._rx = buf[4:]
        return "?", kind

    @staticmethod
    def _ack_from(fields):
        reserved, dsp_load, patch_id, volts, patch_index, fs_ready = fields
        return Ack(dsp_load=dsp_load, patch_id=patch_id,
                   voltage_10=volts & 0xFFFF, voltage_50=(volts >> 16) & 0xFFFF,
                   patch_index=patch_index, fs_ready=fs_ready)

    def _wait_packet(self, kinds, timeout_s=2.0):
        """Pump the stream until a packet of one of `kinds` arrives."""
        deadline = time.monotonic() + timeout_s
        while True:
            parsed = self._parse_one()
            while parsed is not None:
                kind, payload = parsed
                if kind == "T":
                    self.log_messages.append(payload)
                if kind in kinds:
                    return kind, payload
                parsed = self._parse_one()
            if time.monotonic() > deadline:
                raise ProtocolError(
                    f"timed out waiting for {kinds!r} (log: {list(self.log_messages)[-3:]})")
            chunk = self._read_some(200)
            if chunk:
                self._rx += chunk

    def _send(self, data):
        self.dev.write(EP_OUT, data)

    # --- commands ------------------------------------------------------------

    def ping(self, timeout_s=2.0) -> Ack:
        self._send(b"Axop")
        _, ack = self._wait_packet("A", timeout_s)
        return ack

    def fw_info(self, timeout_s=2.0) -> FwInfo:
        self._send(b"AxoV")
        _, payload = self._wait_packet("V", timeout_s)
        version = tuple(payload[0:4])
        fwid, patchmainloc = struct.unpack(">II", payload[4:12])
        self._wait_packet("A", timeout_s)  # AxoV also queues an ack
        return FwInfo(version=version, fwid=fwid, patchmainloc=patchmainloc)

    def write_mem(self, addr, data, timeout_s=5.0) -> Ack:
        """Generic memory write ("AxoW") — the same path patch upload uses."""
        self._send(b"AxoW" + struct.pack("<II", addr, len(data)) + bytes(data))
        _, ack = self._wait_packet("A", timeout_s)
        return ack

    def read_mem(self, addr, length, timeout_s=5.0) -> bytes:
        self._send(b"Axor" + struct.pack("<II", addr, length))
        _, (raddr, data) = self._wait_packet("r", timeout_s)
        if raddr != addr or len(data) != length:
            raise ProtocolError(f"read reply mismatch: {raddr:#x}/{len(data)}")
        self._wait_packet("A", timeout_s)
        return data

    def read_u32(self, addr, timeout_s=2.0) -> int:
        self._send(b"Axoy" + struct.pack("<I", addr))
        _, (raddr, value) = self._wait_packet("y", timeout_s)
        if raddr != addr:
            raise ProtocolError(f"word read reply mismatch: {raddr:#x}")
        self._wait_packet("A", timeout_s)
        return value

    def stop_patch(self, timeout_s=2.0) -> Ack:
        self._send(b"AxoS")
        _, ack = self._wait_packet("A", timeout_s)
        return ack

    def start_patch(self, timeout_s=2.0) -> Ack:
        """Start whatever binary sits at PATCHMAINLOC."""
        self._send(b"Axos")
        _, ack = self._wait_packet("A", timeout_s)
        return ack

    # --- SD card file operations ---------------------------------------------
    # File data rides through the patch RAM buffer on the board, so run these
    # only with the patch stopped. Names are absolute paths on the card.

    def sd_create(self, path, prealloc=0, timeout_s=5.0):
        """Create/truncate `path` and leave it open for sd_append."""
        self._send(b"AxoC" + struct.pack("<I", prealloc)
                   + path.encode("ascii") + b"\x00")
        self._wait_packet("A", timeout_s)

    def sd_append(self, data, timeout_s=10.0):
        self._send(b"AxoA" + struct.pack("<I", len(data)) + bytes(data))
        self._wait_packet("A", timeout_s)

    def sd_close(self, timeout_s=5.0):
        self._send(b"Axoc")
        self._wait_packet("A", timeout_s)

    def _sd_attr_op(self, op, path, extra=b"\x00\x00\x00\x00", timeout_s=5.0):
        # Attribute form: NUL first, then the op char, four bytes of
        # date/time (unused here), then the NUL-terminated path.
        self._send(b"AxoC" + struct.pack("<I", 0) + b"\x00" + op + extra
                   + path.encode("ascii") + b"\x00")

    def sd_delete(self, path, timeout_s=5.0):
        self._sd_attr_op(b"D", path)
        self._wait_packet("A", timeout_s)

    def sd_mkdir(self, path, timeout_s=5.0):
        self._sd_attr_op(b"d", path)
        self._wait_packet("A", timeout_s)

    def sd_info(self, path, timeout_s=5.0):
        """Return (size, timestamp) for `path`, or None if it does not exist."""
        self._sd_attr_op(b"I", path)
        result = []
        kind, payload = self._wait_packet("fA", timeout_s)
        if kind == "f":
            result.append(payload)
            self._wait_packet("A", timeout_s)
        if not result:
            return None
        _name, size, stamp = result[0]
        return size, stamp

    def sd_dir_listing(self, timeout_s=10.0):
        """Walk the whole card. Returns (fs_stats, entries) where fs_stats is
        (free_clusters, cluster_size, block_size) and entries are
        (name, size, timestamp), directories with a trailing '/'.

        Note: this command stops any running patch (firmware behavior), and
        sends no acknowledge — the terminating root entry ends the stream.
        """
        self._send(b"Axod")
        _, stats = self._wait_packet("d", timeout_s)
        entries = []
        while True:
            _, (name, size, stamp) = self._wait_packet("f", timeout_s)
            if name == "/" and size == 0:
                return stats, entries
            entries.append((name, size, stamp))

    # --- conveniences --------------------------------------------------------

    def upload_patch(self, binary, verify=True):
        """Stop any patch, upload `binary` to PATCHMAINLOC, optionally verify."""
        if len(binary) > PATCH_CODE_SIZE:
            raise ValueError(f"patch binary {len(binary)} bytes exceeds "
                             f"{PATCH_CODE_SIZE:#x} code window")
        self.stop_patch()
        self.write_mem(PATCHMAINLOC, binary)
        if verify:
            readback = self.read_mem(PATCHMAINLOC, len(binary))
            if readback != bytes(binary):
                raise ProtocolError("patch upload verify failed")

    def run_patch(self, binary, expect_patch_id=None, settle_s=0.3):
        """Upload and start a patch; verify it reports the expected patch id."""
        self.upload_patch(binary)
        self.start_patch()
        time.sleep(settle_s)
        ack = self.ping()
        # The ack carries patchID as a signed word; compare as 32-bit values.
        if (expect_patch_id is not None
                and (ack.patch_id & 0xFFFFFFFF) != (expect_patch_id & 0xFFFFFFFF)):
            raise ProtocolError(
                f"patch did not start: patch_id={ack.patch_id:#x} "
                f"expected {expect_patch_id:#x} (log: {list(self.log_messages)[-3:]})")
        return ack
