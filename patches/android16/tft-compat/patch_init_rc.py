#!/usr/bin/env python3
"""Enable the TFT input shim only in the verified July Android 16 HWC service."""

import argparse
import hashlib
from pathlib import Path


SOURCE_SHA256 = "f0ccfee6f821af70314f1a6005a5151d17ef1005425f158e31df023e108874d2"
NEEDLE = (
    "service vendor.hwcomposer-2-1 "
    "/vendor/bin/hw/android.hardware.graphics.composer@2.1-service "
    "--desktop_file_hint=Waydroid.desktop\n"
    "    override\n"
)
REPLACEMENT = NEEDLE + "    setenv LD_PRELOAD /vendor/lib64/libtftpointer.so\n"
OLD_REPLACEMENT = NEEDLE + "    setenv LD_PRELOAD /system/lib64/libtftpointer.so\n"


def patch(source: bytes) -> bytes:
    text = source.decode("utf-8")
    if REPLACEMENT in text:
        if text.count(REPLACEMENT) != 1:
            raise ValueError("duplicate HWC service declaration")
        return source
    if OLD_REPLACEMENT in text:
        if text.count(OLD_REPLACEMENT) != 1:
            raise ValueError("duplicate old HWC service declaration")
        return text.replace(OLD_REPLACEMENT, REPLACEMENT).encode("utf-8")
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("unrecognized Waydroid Android init script")
    if text.count(NEEDLE) != 1:
        raise ValueError("HWC service declaration missing or duplicated")
    return text.replace(NEEDLE, REPLACEMENT).encode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(patch(args.input.read_bytes()))
    print("patched HWC init script:", args.output)


if __name__ == "__main__":
    main()
