"""Bake an SD bank: soundgraph patches in, a standalone Axoloti card out.

    .venv/bin/python tools/bake-bank.py OUT_DIR patch1.json [patch2.json ...]
        [--board]           also write the bank to the card in the connected
                            board over USB (needs a mounted FAT32 microSD)
        [--names a,b,...]   bank entry names (default: patch file stems)

Card layout (firmware 1.0.12-2 conventions, patch.c):

    /start.bin          entry 0's binary — what the board boots into with no
                        computer attached
    /index.axb          one line per entry, "<name>.axp\\n"; the firmware
                        strips the last four characters and loads
                        /<name>/patch.bin (falling back to /start.bin)
    /<name>/patch.bin   the compiled patch
    /<name>/b<N>.raw    its sample/phrase buffers, raw float32; the patch
                        loads them into SDRAM at init through FatFs

Every baked patch listens for MIDI Program Change on any transport and
switches the bank through the firmware's own LoadPatchIndexed — program 0 is
the first line of index.axb. Fastest path to a card: bake to OUT_DIR and copy
with a card reader; --board writes over USB at ~60 KB/s instead.
"""

import argparse
import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "sgaxo"))
sys.path.insert(0, str(_HERE.parent / "driver"))

import codegen  # noqa: E402

MAX_SD_PATCH = 0xE000  # sdcard_loadPatch1's read cap; the linker's 0xB000
                       # code window keeps every binary under it anyway.


def sanitize(name):
    clean = "".join(ch if (ch.isalnum() or ch in "-_") else "-" for ch in name)
    if len(clean) < 1:
        raise SystemExit(f"cannot derive a bank name from {name!r}")
    return clean


def bake(out_dir, patches, names, to_board):
    out_dir = pathlib.Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    index_lines = []
    entries = []  # (name, binary, [(filename, blob)])

    for path, name in zip(patches, names):
        print(f"compiling {path} as bank entry {len(entries)} ({name!r})")
        binary, _pid, buffers = codegen.build_patch(
            pathlib.Path(path), frames=0, name=name, zero_input=False,
            sd_bank_name=name)
        assert len(binary) <= MAX_SD_PATCH
        files = [(sd_name, blob) for _addr, blob, sd_name in buffers]
        entries.append((name, binary, files))
        index_lines.append(f"{name}.axp\n")

    for name, binary, files in entries:
        entry_dir = out_dir / name
        entry_dir.mkdir(exist_ok=True)
        (entry_dir / "patch.bin").write_bytes(binary)
        for filename, blob in files:
            (entry_dir / filename).write_bytes(blob)
    (out_dir / "start.bin").write_bytes(entries[0][1])
    (out_dir / "index.axb").write_text("".join(index_lines))
    total = sum(len(b) + sum(len(f) for _n, f in fs)
                for _e, b, fs in entries)
    print(f"baked {len(entries)} entries, {total} bytes -> {out_dir}")
    print("copy the contents onto a FAT32 microSD (card root = this dir), "
          "insert, power the board without USB — it boots start.bin; "
          "MIDI Program Change selects entries.")

    if not to_board:
        return

    from axoproto import Axoloti  # noqa: E402
    board = Axoloti()
    board.stop_patch()
    board.sd_info("/")  # provokes a mount attempt
    if board.ping().fs_ready != 1:
        raise SystemExit("--board: no mounted SD card in the board "
                         "(insert a FAT32 microSD and retry)")

    def write_file(sd_path, blob):
        print(f"  {sd_path} ({len(blob)} bytes)")
        board.sd_create(sd_path, prealloc=len(blob))
        for off in range(0, len(blob), 16384):
            board.sd_append(blob[off:off + 16384])
        board.sd_close()
        info = board.sd_info(sd_path)
        if info is None or info[0] != len(blob):
            raise SystemExit(f"verify failed for {sd_path}: {info}")

    print("writing to the board's card over USB:")
    for name, binary, files in entries:
        board.sd_mkdir(f"/{name}")
        write_file(f"/{name}/patch.bin", binary)
        for filename, blob in files:
            write_file(f"/{name}/{filename}", blob)
    write_file("/start.bin", entries[0][1])
    write_file("/index.axb", "".join(index_lines).encode("ascii"))
    board.close()
    print("card written and size-verified. Power-cycle without USB to test.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out_dir")
    parser.add_argument("patches", nargs="+")
    parser.add_argument("--board", action="store_true")
    parser.add_argument("--names", default=None)
    args = parser.parse_args()
    if args.names:
        names = [sanitize(n) for n in args.names.split(",")]
        if len(names) != len(args.patches):
            raise SystemExit("--names count must match patch count")
    else:
        names = [sanitize(pathlib.Path(p).stem) for p in args.patches]
    if len(set(names)) != len(names):
        raise SystemExit(f"duplicate bank names: {names}")
    bake(args.out_dir, args.patches, names, args.board)


if __name__ == "__main__":
    main()
