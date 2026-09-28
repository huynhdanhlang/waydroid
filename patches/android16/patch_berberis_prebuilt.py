#!/usr/bin/env python3
"""Backport a low-address JIT mmap retry to the pinned Android 16 Berberis.

The July translator requests 4 MiB executable mappings with MAP_32BIT. Once
the kernel's 1-2 GiB search range fills, mmap(NULL) fails even though free
space remains below 1 GiB. This patch retries only failed 4 MiB, NULL,
MAP_32BIT requests with non-fixed hints below 1 GiB. It changes no game binary.
"""

import argparse
import hashlib
import struct
from pathlib import Path


SOURCE_SHA256 = "fbadc774c989534a567e6af8fd16d2c00727b1f1d9cc778bf538d6b59ed9776d"
SOURCE_BUILD_ID = bytes.fromhex("2810e5b44895c4ea0b1ad6882ea73b73")
BUILD_ID_NOTE_OFFSET = 0x2A0
PATCH_ID = b"waydroid-berberis-low32-exec-hint-v2"
MMAP_CALL_VA = 0x45009A
MMAP_CALL_BYTES = bytes.fromhex("e8 a1 f5 00 00")
MMAP_PLT_VA = 0x45F640
CAVE_VA = 0x45FE70
PT_LOAD = 1
PF_X = 1

# x86_64 trampoline: call mmap normally, then only for failed NULL MAP_32BIT
# requests scan free low-address slots in increments of the requested length.
# The byte sequence was assembled from tft_retry in the regression analysis;
# rel32 operands at the two call sites are filled below for this exact ELF.
TRAMPOLINE = bytes.fromhex(
    "535756525141504151e8000000004883f8ff75588b4c2410f7c140000000744c"
    "48837c242800754448817c2420000040007539bb0000001e4889df488b742420"
    "488b542418488b4c24104c8b4424084c8b0c24e8000000004883f8ff750e48"
    "035c24204881fb0000004072cc41594158595a5e5f5bc3"
)
CALL_OFFSETS = (0x09, 0x53)


def patch(source: bytes) -> bytes:
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("input does not match the verified July Berberis library")
    if source[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<HH", source, 16) != (3, 62):
        raise ValueError("expected little-endian x86_64 ET_DYN")

    data = bytearray(source)
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    if phentsize != 56:
        raise ValueError("unexpected ELF program header size")
    loads = []
    executable = None
    for index in range(phnum):
        header = phoff + index * phentsize
        p_type, flags, fileoff, vaddr, _, filesz, memsz, _ = struct.unpack_from(
            "<IIQQQQQQ", data, header
        )
        if p_type != PT_LOAD:
            continue
        loads.append((fileoff, filesz))
        if flags & PF_X and vaddr <= MMAP_CALL_VA < vaddr + filesz:
            executable = (header, fileoff, vaddr, filesz, memsz)
    if executable is None:
        raise ValueError("mmap call not in an executable LOAD segment")
    header, fileoff, vaddr, filesz, memsz = executable
    if filesz != memsz or (fileoff + filesz, vaddr + filesz) != (CAVE_VA, CAVE_VA):
        raise ValueError("unexpected executable segment end")
    call_offset = fileoff + MMAP_CALL_VA - vaddr
    if data[call_offset : call_offset + 5] != MMAP_CALL_BYTES:
        raise ValueError("Berberis mmap call differs from the verified build")

    payload = bytearray(TRAMPOLINE)
    for call_at in CALL_OFFSETS:
        if payload[call_at : call_at + 5] != b"\xe8\0\0\0\0":
            raise ValueError("invalid trampoline mmap call slot")
        struct.pack_into("<i", payload, call_at + 1,
                         MMAP_PLT_VA - (CAVE_VA + call_at + 5))

    cave_offset = fileoff + CAVE_VA - vaddr
    next_load = min((start for start, _ in loads if start > cave_offset), default=len(data))
    if cave_offset + len(payload) > next_load or any(data[cave_offset : cave_offset + len(payload)]):
        raise ValueError("no empty executable padding for the retry")
    data[call_offset : call_offset + 5] = b"\xe8" + struct.pack(
        "<i", CAVE_VA - (MMAP_CALL_VA + 5)
    )
    data[cave_offset : cave_offset + len(payload)] = payload
    struct.pack_into("<QQ", data, header + 32, filesz + len(payload), memsz + len(payload))

    if struct.unpack_from("<III", data, BUILD_ID_NOTE_OFFSET) != (4, 16, 3):
        raise ValueError("unexpected GNU Build ID note layout")
    if data[BUILD_ID_NOTE_OFFSET + 12 : BUILD_ID_NOTE_OFFSET + 16] != b"GNU\0":
        raise ValueError("unexpected GNU Build ID note owner")
    note_at = BUILD_ID_NOTE_OFFSET + 16
    if data[note_at : note_at + 16] != SOURCE_BUILD_ID:
        raise ValueError("Berberis Build ID differs")
    data[note_at : note_at + 16] = hashlib.sha256(source + PATCH_ID).digest()[:16]
    return bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
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
