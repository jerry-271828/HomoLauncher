#!/usr/bin/env python3
"""Apply and verify HomoLauncher's small LWJGL compatibility patches.

The bundled jar is based on an older LWJGL build and is patched in place instead
of being rebuilt from upstream.  Keeping the bytecode construction here makes
the binary change reproducible and, more importantly, lets CI verify it.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import struct
import tempfile
import zipfile


U2 = lambda value: struct.pack(">H", value)
U4 = lambda value: struct.pack(">I", value)


class ClassEditor:
    def __init__(self, data: bytes) -> None:
        if data[:4] != b"\xca\xfe\xba\xbe":
            raise ValueError("not a Java class file")

        self.data = data
        self.original_cp_count = struct.unpack_from(">H", data, 8)[0]
        self.cp_count = self.original_cp_count
        self.entries: dict[int, tuple[int, tuple[int, ...] | str]] = {}
        self.added = bytearray()

        pos = 10
        index = 1
        while index < self.original_cp_count:
            tag = data[pos]
            pos += 1
            if tag == 1:
                length = struct.unpack_from(">H", data, pos)[0]
                pos += 2
                value = data[pos : pos + length].decode("utf-8")
                pos += length
                self.entries[index] = (tag, value)
            elif tag in (7, 8, 16, 19, 20):
                value = struct.unpack_from(">H", data, pos)[0]
                pos += 2
                self.entries[index] = (tag, (value,))
            elif tag == 15:
                kind, reference = struct.unpack_from(">BH", data, pos)
                pos += 3
                self.entries[index] = (tag, (kind, reference))
            elif tag in (3, 4):
                value = struct.unpack_from(">I", data, pos)[0]
                pos += 4
                self.entries[index] = (tag, (value,))
            elif tag in (9, 10, 11, 12, 17, 18):
                first, second = struct.unpack_from(">HH", data, pos)
                pos += 4
                self.entries[index] = (tag, (first, second))
            elif tag in (5, 6):
                high, low = struct.unpack_from(">II", data, pos)
                pos += 8
                self.entries[index] = (tag, (high, low))
                index += 1
            else:
                raise ValueError(f"unsupported constant-pool tag {tag}")
            index += 1

        self.cp_end = pos
        self.utf_by_value = {
            value: index
            for index, (tag, value) in self.entries.items()
            if tag == 1
        }
        self.integer_by_value = {
            values[0]: index
            for index, (tag, values) in self.entries.items()
            if tag == 3
        }
        self.class_by_name: dict[str, int] = {}
        self.nt_by_value: dict[tuple[str, str], int] = {}
        self.method_by_value: dict[tuple[str, str, str], int] = {}
        self._rebuild_reference_maps()

    def _utf(self, index: int) -> str:
        tag, value = self.entries[index]
        if tag != 1 or not isinstance(value, str):
            raise ValueError(f"constant #{index} is not UTF-8")
        return value

    def _rebuild_reference_maps(self) -> None:
        for index, (tag, values) in self.entries.items():
            if tag == 7:
                assert not isinstance(values, str)
                self.class_by_name[self._utf(values[0])] = index
            elif tag == 12:
                assert not isinstance(values, str)
                self.nt_by_value[(self._utf(values[0]), self._utf(values[1]))] = index

        for index, (tag, values) in self.entries.items():
            if tag != 10:
                continue
            assert not isinstance(values, str)
            class_index, nt_index = values
            class_values = self.entries[class_index][1]
            nt_values = self.entries[nt_index][1]
            assert not isinstance(class_values, str)
            assert not isinstance(nt_values, str)
            owner = self._utf(class_values[0])
            name = self._utf(nt_values[0])
            descriptor = self._utf(nt_values[1])
            self.method_by_value[(owner, name, descriptor)] = index

    def _append(self, tag: int, body: bytes, value: tuple[int, ...] | str) -> int:
        index = self.cp_count
        self.cp_count += 1
        self.added.extend(bytes((tag,)) + body)
        self.entries[index] = (tag, value)
        return index

    def add_utf(self, value: str) -> int:
        existing = self.utf_by_value.get(value)
        if existing is not None:
            return existing
        encoded = value.encode("utf-8")
        index = self._append(1, U2(len(encoded)) + encoded, value)
        self.utf_by_value[value] = index
        return index

    def add_integer(self, value: int) -> int:
        unsigned = value & 0xFFFFFFFF
        existing = self.integer_by_value.get(unsigned)
        if existing is not None:
            return existing
        index = self._append(3, U4(unsigned), (unsigned,))
        self.integer_by_value[unsigned] = index
        return index

    def add_class(self, name: str) -> int:
        existing = self.class_by_name.get(name)
        if existing is not None:
            return existing
        name_index = self.add_utf(name)
        index = self._append(7, U2(name_index), (name_index,))
        self.class_by_name[name] = index
        return index

    def add_name_and_type(self, name: str, descriptor: str) -> int:
        key = (name, descriptor)
        existing = self.nt_by_value.get(key)
        if existing is not None:
            return existing
        name_index = self.add_utf(name)
        descriptor_index = self.add_utf(descriptor)
        index = self._append(
            12,
            U2(name_index) + U2(descriptor_index),
            (name_index, descriptor_index),
        )
        self.nt_by_value[key] = index
        return index

    def add_methodref(self, owner: str, name: str, descriptor: str) -> int:
        key = (owner, name, descriptor)
        existing = self.method_by_value.get(key)
        if existing is not None:
            return existing
        class_index = self.add_class(owner)
        nt_index = self.add_name_and_type(name, descriptor)
        index = self._append(10, U2(class_index) + U2(nt_index), (class_index, nt_index))
        self.method_by_value[key] = index
        return index

    @staticmethod
    def _skip_members(data: bytes, pos: int) -> int:
        count = struct.unpack_from(">H", data, pos)[0]
        pos += 2
        for _ in range(count):
            attribute_count = struct.unpack_from(">H", data, pos + 6)[0]
            pos += 8
            for _ in range(attribute_count):
                length = struct.unpack_from(">I", data, pos + 2)[0]
                pos += 6 + length
        return pos

    def replace_method_codes(
        self,
        replacements: dict[tuple[str, str], tuple[int, int, bytes, list[tuple[str, bytes]]]],
    ) -> bytes:
        tail = self.data[self.cp_end :]
        pos = 6
        interface_count = struct.unpack_from(">H", tail, pos)[0]
        pos += 2 + 2 * interface_count
        pos = self._skip_members(tail, pos)

        method_count_offset = pos
        method_count = struct.unpack_from(">H", tail, pos)[0]
        pos += 2
        out = bytearray(tail[:pos])
        replaced: set[tuple[str, str]] = set()
        code_name_index = self.add_utf("Code")

        for _ in range(method_count):
            method_start = pos
            _, name_index, descriptor_index, attribute_count = struct.unpack_from(">HHHH", tail, pos)
            pos += 8
            key = (self._utf(name_index), self._utf(descriptor_index))
            attributes: list[tuple[int, bytes]] = []
            for _ in range(attribute_count):
                attribute_name_index = struct.unpack_from(">H", tail, pos)[0]
                length = struct.unpack_from(">I", tail, pos + 2)[0]
                end = pos + 6 + length
                attributes.append((attribute_name_index, tail[pos:end]))
                pos = end

            replacement = replacements.get(key)
            if replacement is None:
                out.extend(tail[method_start:pos])
                continue

            max_stack, max_locals, code, nested_attributes = replacement
            nested = bytearray()
            for nested_name, body in nested_attributes:
                nested.extend(U2(self.add_utf(nested_name)) + U4(len(body)) + body)
            code_body = (
                U2(max_stack)
                + U2(max_locals)
                + U4(len(code))
                + code
                + U2(0)
                + U2(len(nested_attributes))
                + nested
            )
            code_attribute = U2(code_name_index) + U4(len(code_body)) + code_body

            kept = [raw for attribute_name_index, raw in attributes if self._utf(attribute_name_index) != "Code"]
            out.extend(tail[method_start : method_start + 6])
            out.extend(U2(len(kept) + 1))
            for raw in kept:
                out.extend(raw)
            out.extend(code_attribute)
            replaced.add(key)

        out.extend(tail[pos:])
        missing = set(replacements) - replaced
        if missing:
            names = ", ".join(f"{name}{descriptor}" for name, descriptor in sorted(missing))
            raise ValueError(f"methods not found: {names}")

        if method_count_offset >= len(tail):
            raise AssertionError("invalid method table")
        return (
            self.data[:8]
            + U2(self.cp_count)
            + self.data[10 : self.cp_end]
            + self.added
            + bytes(out)
        )


def patch_gl11c(data: bytes) -> bytes:
    editor = ClassEditor(data)
    unpack_image_height = editor.add_integer(0x806E)
    pixel_store = editor.add_methodref("org/lwjgl/opengl/GL11C", "glPixelStorei", "(II)V")
    mem_address = editor.add_methodref(
        "org/lwjgl/system/MemoryUtil",
        "memAddress",
        "(Ljava/nio/ByteBuffer;)J",
    )
    native_upload = editor.add_methodref(
        "org/lwjgl/opengl/GL11C",
        "nglTexSubImage2D",
        "(IIIIIIIIJ)V",
    )

    # GL_UNPACK_IMAGE_HEIGHT is irrelevant to TexSubImage2D.  Minecraft 26.x
    # leaves it set after a PBO upload; Mesa 25.0.1 then overreads direct pixel
    # buffers in its threaded staging path.  Clear it before direct uploads.
    code = b"".join(
        (
            bytes((0x13,)) + U2(unpack_image_height),  # ldc_w GL_UNPACK_IMAGE_HEIGHT
            bytes((0x03, 0xB8)) + U2(pixel_store),  # iconst_0; invokestatic glPixelStorei
            bytes((0x1A, 0x1B, 0x1C, 0x1D)),
            bytes((0x15, 0x04, 0x15, 0x05, 0x15, 0x06, 0x15, 0x07)),
            bytes((0x19, 0x08, 0xB8)) + U2(mem_address),
            bytes((0xB8,)) + U2(native_upload),
            bytes((0xB1,)),
        )
    )
    descriptor = "(IIIIIIIILjava/nio/ByteBuffer;)V"
    return editor.replace_method_codes({("glTexSubImage2D", descriptor): (10, 9, code, [])})


def patch_stb_resize(data: bytes) -> bytes:
    editor = ClassEditor(data)
    wrap = editor.add_methodref(
        "org/lwjgl/system/MemoryUtil",
        "memByteBuffer",
        "(JI)Ljava/nio/ByteBuffer;",
    )
    resize = editor.add_methodref(
        "org/lwjgl/stb/STBImageResize",
        "stbir_resize_uint8",
        "(Ljava/nio/ByteBuffer;IIILjava/nio/ByteBuffer;IIII)Z",
    )
    maximum = editor.add_methodref("java/lang/Math", "max", "(II)I")

    def packed_size(pointer_load: bytes, stride: int, width: int, height: int) -> bytes:
        return b"".join(
            (
                pointer_load,
                bytes((0x15, stride, 0x15, width, 0x15, 0x0A, 0x68)),
                bytes((0xB8,)) + U2(maximum),
                bytes((0x15, height, 0x68, 0xB8)) + U2(wrap),
            )
        )

    # A zero STB stride means tightly packed pixels.  The native pointer must
    # therefore be wrapped as max(stride, width * channels) * height bytes.
    code = b"".join(
        (
            packed_size(bytes((0x1E,)), 4, 2, 3),
            bytes((0x3A, 0x0B)),
            packed_size(bytes((0x16, 0x05)), 9, 7, 8),
            bytes((0x3A, 0x0C)),
            bytes(
                (
                    0x19,
                    0x0B,
                    0x15,
                    0x02,
                    0x15,
                    0x03,
                    0x15,
                    0x04,
                    0x19,
                    0x0C,
                    0x15,
                    0x07,
                    0x15,
                    0x08,
                    0x15,
                    0x09,
                    0x15,
                    0x0A,
                )
            ),
            bytes((0xB8,)) + U2(resize),
            bytes((0x99, 0x00, 0x06, 0x16, 0x05, 0xAD, 0x09, 0xAD)),
        )
    )
    if len(code) != 68 or code[60:63] != bytes((0x99, 0x00, 0x06)):
        raise AssertionError("unexpected STB patch layout")
    stack_map = U2(1) + bytes((251,)) + U2(66)
    descriptor = "(JIIIJIIII)J"
    return editor.replace_method_codes(
        {("nstbir_resize_uint8_linear", descriptor): (12, 13, code, [("StackMapTable", stack_map)])}
    )


PATCHES = {
    "org/lwjgl/opengl/GL11C.class": patch_gl11c,
    "org/lwjgl/stb/STBImageResize.class": patch_stb_resize,
}


def inspect_jar(path: Path) -> tuple[dict[str, bytes], dict[str, bytes]]:
    original: dict[str, bytes] = {}
    patched: dict[str, bytes] = {}
    with zipfile.ZipFile(path) as jar:
        for name, patcher in PATCHES.items():
            data = jar.read(name)
            original[name] = data
            patched[name] = patcher(data)
    return original, patched


def write_jar(source: Path, output: Path, patched: dict[str, bytes]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(prefix=f".{output.name}.", dir=output.parent, delete=False)
    temporary = Path(handle.name)
    handle.close()
    try:
        with zipfile.ZipFile(source) as input_jar, zipfile.ZipFile(temporary, "w") as output_jar:
            for item in input_jar.infolist():
                output_jar.writestr(item, patched.get(item.filename, input_jar.read(item.filename)))
            output_jar.comment = input_jar.comment
        os.chmod(temporary, source.stat().st_mode)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    default_jar = repo_root / "entry/src/main/resources/resfile/lwjgl.jar"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jar", nargs="?", type=Path, default=default_jar)
    parser.add_argument("--output", type=Path, help="write to a different jar instead of patching in place")
    parser.add_argument("--check", action="store_true", help="only verify that all patches are present")
    args = parser.parse_args()

    source = args.jar.resolve()
    original, patched = inspect_jar(source)
    changed = [name for name in PATCHES if original[name] != patched[name]]
    if args.check:
        if changed:
            print("missing or stale LWJGL patches: " + ", ".join(changed))
            return 1
        print(f"verified LWJGL runtime patches in {source}")
        return 0

    output = (args.output or source).resolve()
    if not changed and output == source:
        print(f"LWJGL runtime patches already current in {source}")
        return 0
    write_jar(source, output, patched)
    print(f"patched LWJGL runtime written to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
