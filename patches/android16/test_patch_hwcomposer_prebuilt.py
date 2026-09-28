#!/usr/bin/env python3
"""Check that the pinned HWC binary forwards pointer-enter coordinates."""

import argparse
import struct
from pathlib import Path

from patch_hwcomposer_prebuilt import patch


ENTER_VA = 0x42760
MOTION_VA = 0x427A0
CONFIGURE_STORE_VA = 0x41439


def test_pointer_enter(source: bytes) -> None:
    result = patch(source)
    assert result[ENTER_VA] == 0xE9, "pointer enter still ignores the initial position"
    jump = struct.unpack_from("<i", result, ENTER_VA + 1)[0]
    cave = ENTER_VA + 5 + jump
    assert 0x6F290 <= cave < 0x70000, "pointer enter jump leaves executable padding"

    # The trampoline must call the original enter body and then the verified
    # motion callback. The latter writes ABS_X/ABS_Y into the pointer FIFO.
    calls = []
    for offset in range(cave, min(cave + 100, 0x70000) - 4):
        if result[offset] == 0xE8:
            calls.append(offset + 5 + struct.unpack_from("<i", result, offset + 1)[0])
    assert ENTER_VA + 5 in calls, "original enter handling was lost"
    assert MOTION_VA in calls, "initial pointer position is not forwarded"


def test_duplicate_configure(source: bytes) -> None:
    result = patch(source)
    assert result[CONFIGURE_STORE_VA] == 0xE9, (
        "duplicate window configure still recreates the touch device"
    )
    jump = struct.unpack_from("<i", result, CONFIGURE_STORE_VA + 1)[0]
    cave = CONFIGURE_STORE_VA + 5 + jump
    assert 0x6F290 <= cave < 0x70000, "configure guard leaves executable padding"
    assert b"\xa0\x00\x00\x00" in result[cave : cave + 48], (
        "configure guard does not inspect the first-configure flag"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    args = parser.parse_args()
    test_pointer_enter(args.original.read_bytes())
    test_duplicate_configure(args.original.read_bytes())
    print("pointer enter forwards initial coordinates")
    print("duplicate configure preserves the touch device")
