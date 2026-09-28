#!/usr/bin/env python3
"""Patch the July 2026 WayDroid-ATV HWC prebuilt's verified input/crash bugs.

This is a temporary binary backport of the source fix in commit 2c141e2.
It applies only to the exact library identified below and writes a new file;
the input image and library are never modified.
"""

import argparse
import hashlib
import struct
from pathlib import Path


SOURCE_SHA256 = "9908498c71cbe8e52ec4bc4b532ebebcd6f55c0342590ecb63358c240757b931"
SOURCE_BUILD_ID = bytes.fromhex("518e927a66120147f1eedc924d230c04")
FUNCTION_VA = 0x39680
ORIGINAL_PROLOGUE = bytes.fromhex("55 48 89 e5 41 57")
ENTER_VA = 0x42760
ENTER_PROLOGUE = bytes.fromhex("48 85 c9 74 20")
MOTION_VA = 0x427A0
MOTION_PROLOGUE = bytes.fromhex("55 48 89 e5 41 57")
ENTER_CAVE_VA = 0x6F2B0
CONFIGURE_STORE_VA = 0x41439
CONFIGURE_STORE = bytes.fromhex("89 93 c0 02 00 00")
CONFIGURE_CAVE_VA = 0x6F310
BUILD_ID_NOTE_OFFSET = 0x2A0
PATCH_ID = b"waydroid-hwc-null-handle-pointer-enter-configure-v3"
PT_LOAD = 1
PF_X = 1


def patch(source: bytes) -> bytes:
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("input does not match the verified 2026-07-17 hwcomposer")
    if source[:4] != b"\x7fELF" or source[4:6] != b"\x02\x01":
        raise ValueError("expected little-endian ELF64")
    if struct.unpack_from("<HH", source, 16) != (3, 62):
        raise ValueError("expected x86_64 ET_DYN")

    data = bytearray(source)
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    if phentsize != 56:
        raise ValueError("unexpected ELF program header size")

    loads = []
    executable = None
    for i in range(phnum):
        offset = phoff + i * phentsize
        p_type, flags, fileoff, vaddr, _, filesz, memsz, _ = struct.unpack_from(
            "<IIQQQQQQ", data, offset
        )
        if p_type != PT_LOAD:
            continue
        loads.append((fileoff, filesz))
        if flags & PF_X and vaddr <= FUNCTION_VA < vaddr + filesz:
            executable = (offset, fileoff, vaddr, filesz, memsz)
    if executable is None:
        raise ValueError("function not in an executable LOAD segment")
    header_offset, fileoff, vaddr, filesz, memsz = executable
    if filesz != memsz:
        raise ValueError("executable LOAD segment has unexpected memory size")

    entry_offset = fileoff + FUNCTION_VA - vaddr
    if data[entry_offset : entry_offset + 6] != ORIGINAL_PROLOGUE:
        raise ValueError("function prologue differs from the verified build")

    cave_offset = fileoff + filesz
    cave_va = vaddr + filesz
    if (cave_offset, cave_va) != (0x6F290, 0x6F290):
        raise ValueError("executable segment ends at an unexpected address")

    # get_wl_buffer(pdev, layer, pos) receives layer in RSI. A null handle
    # means there is no client target yet, so return nullptr in RAX. The
    # caller already handles nullptr and closes the acquire fence.
    prologue = bytes.fromhex("48 8b 46 10 48 85 c0 75 03 31 c0 c3")
    replay = ORIGINAL_PROLOGUE
    jump_back_at = cave_va + len(prologue) + len(replay)
    jump_back = b"\xe9" + struct.pack("<i", FUNCTION_VA + 6 - (jump_back_at + 5))
    payload = prologue + replay + jump_back
    next_load = min((start for start, _ in loads if start > cave_offset), default=len(data))
    if cave_offset + len(payload) > next_load:
        raise ValueError("no room before the next LOAD segment")
    if any(data[cave_offset : cave_offset + len(payload)]):
        raise ValueError("executable segment padding is not empty")

    jump_to_cave = b"\xe9" + struct.pack("<i", cave_va - (FUNCTION_VA + 5))
    data[entry_offset : entry_offset + 6] = jump_to_cave + b"\x90"
    data[cave_offset : cave_offset + len(payload)] = payload

    # The HWC pointer-enter listener ignores Wayland's initial surface x/y.
    # If the user clicks before moving, the input shim has no position and
    # cannot convert that first mouse button into a touchscreen press. Replay
    # the original enter body, then call its own motion callback with sx/sy.
    enter_offset = fileoff + ENTER_VA - vaddr
    motion_offset = fileoff + MOTION_VA - vaddr
    if data[enter_offset : enter_offset + 5] != ENTER_PROLOGUE:
        raise ValueError("pointer enter differs from the verified build")
    if data[motion_offset : motion_offset + 6] != MOTION_PROLOGUE:
        raise ValueError("pointer motion differs from the verified build")
    enter_cave_offset = fileoff + ENTER_CAVE_VA - vaddr
    if enter_cave_offset < cave_offset + len(payload):
        raise ValueError("pointer cave overlaps null-handle patch")

    enter_payload = bytearray()

    def emit(hex_bytes: str) -> None:
        enter_payload.extend(bytes.fromhex(hex_bytes))

    def emit_call(target: int) -> None:
        call_va = ENTER_CAVE_VA + len(enter_payload)
        enter_payload.extend(b"\xe8" + struct.pack("<i", target - (call_va + 5)))

    emit("48 85 c9")                  # test rcx, rcx (surface)
    emit("0f 84 00 00 00 00")         # je null_surface
    emit("53 41 54 41 55 41 56 41 57")  # preserve callee-saved registers
    emit("48 89 fb 49 89 f4 45 89 c5 45 89 ce")  # data, pointer, sx, sy
    emit_call(ENTER_VA + 5)          # original enter body and cursor handler
    emit("48 89 df 4c 89 e6 31 d2 44 89 e9 45 89 f0")
    emit_call(MOTION_VA)             # pointer motion writes ABS_X/ABS_Y
    emit("41 5f 41 5e 41 5d 41 5c 5b c3")
    null_surface_at = len(enter_payload)
    emit("c3")
    struct.pack_into("<i", enter_payload, 5, null_surface_at - 9)

    if enter_cave_offset + len(enter_payload) > next_load:
        raise ValueError("no room for pointer enter trampoline")
    if any(data[enter_cave_offset : enter_cave_offset + len(enter_payload)]):
        raise ValueError("pointer enter cave is not empty")
    data[enter_offset : enter_offset + 5] = b"\xe9" + struct.pack(
        "<i", ENTER_CAVE_VA - (ENTER_VA + 5)
    )
    data[enter_cave_offset : enter_cave_offset + len(enter_payload)] = enter_payload

    # KWin can send xdg_toplevel.configure again for a focus/state change
    # without changing the requested dimensions. HWC otherwise destroys and
    # recreates its touch FIFO for each such event, interrupting held drags.
    # Preserve the first configure; skip duplicates once xdg_surface has been
    # configured and the previous requested width/height are identical.
    configure_offset = fileoff + CONFIGURE_STORE_VA - vaddr
    if data[configure_offset : configure_offset + 6] != CONFIGURE_STORE:
        raise ValueError("configure handler differs from the verified build")
    configure_cave_offset = fileoff + CONFIGURE_CAVE_VA - vaddr
    if configure_cave_offset < enter_cave_offset + len(enter_payload):
        raise ValueError("configure cave overlaps pointer enter patch")
    configure_payload = bytearray.fromhex(
        "80 bf a0 00 00 00 00 "  # window->configured
        "74 17 "                 # first configure: replay original store
        "44 39 b3 c0 02 00 00 "  # width == display->req_width
        "75 0e "                 # changed width: replay
        "44 39 bb c4 02 00 00 "  # height == display->req_height
        "75 05"                  # changed height: replay
    )

    def emit_jump(target: int) -> None:
        jump_va = CONFIGURE_CAVE_VA + len(configure_payload)
        configure_payload.extend(b"\xe9" + struct.pack("<i", target - (jump_va + 5)))

    emit_jump(0x41529)             # duplicate: return via stack-canary epilogue
    configure_payload.extend(CONFIGURE_STORE)
    emit_jump(CONFIGURE_STORE_VA + len(CONFIGURE_STORE))
    if configure_cave_offset + len(configure_payload) > next_load:
        raise ValueError("no room for configure trampoline")
    if any(data[configure_cave_offset : configure_cave_offset + len(configure_payload)]):
        raise ValueError("configure cave is not empty")
    data[configure_offset : configure_offset + 6] = b"\xe9" + struct.pack(
        "<i", CONFIGURE_CAVE_VA - (CONFIGURE_STORE_VA + 5)
    ) + b"\x90"
    data[configure_cave_offset : configure_cave_offset + len(configure_payload)] = configure_payload
    new_size = CONFIGURE_CAVE_VA + len(configure_payload) - vaddr
    struct.pack_into("<QQ", data, header_offset + 32, new_size, new_size)

    note_header = struct.unpack_from("<III", data, BUILD_ID_NOTE_OFFSET)
    if note_header != (4, 16, 3):
        raise ValueError("unexpected GNU Build ID note layout")
    if data[BUILD_ID_NOTE_OFFSET + 12 : BUILD_ID_NOTE_OFFSET + 16] != b"GNU\0":
        raise ValueError("GNU Build ID note owner differs")
    note_id_at = BUILD_ID_NOTE_OFFSET + 16
    if data[note_id_at : note_id_at + 16] != SOURCE_BUILD_ID:
        raise ValueError("Build ID differs from the verified library")
    data[note_id_at : note_id_at + 16] = hashlib.sha256(source + PATCH_ID).digest()[:16]
    return bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="untouched July 2026 hwcomposer.waydroid.so")
    parser.add_argument("output", type=Path, help="new patched library path")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists; refusing to overwrite it")
    result = patch(args.input.read_bytes())
    with args.output.open("xb") as output:
        output.write(result)
    args.output.chmod(0o644)
    print(f"patched: {args.output}")
    print(f"sha256: {hashlib.sha256(result).hexdigest()}")


if __name__ == "__main__":
    main()
