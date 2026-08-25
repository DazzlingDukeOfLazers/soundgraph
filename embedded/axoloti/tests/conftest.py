import pathlib
import sys

import pytest

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "driver"))
sys.path.insert(0, str(_HERE))

from axoproto import Axoloti, BoardNotFound  # noqa: E402

PATCH_BUILD_DIR = _HERE.parent / "patches" / "build"


@pytest.fixture(scope="session")
def board():
    """A claimed connection to the Axoloti Core; skips cleanly with no board."""
    try:
        b = Axoloti()
    except BoardNotFound as e:
        pytest.skip(f"hardware unavailable: {e}")
    yield b
    try:
        b.stop_patch()
    except Exception:
        pass
    b.close()


def load_patch_bin(name):
    path = PATCH_BUILD_DIR / f"{name}.bin"
    if not path.exists():
        pytest.skip(f"{path} missing — run make in patches/ (needs sdk + "
                    "arm-none-eabi toolchain, see README)")
    return path.read_bytes()
