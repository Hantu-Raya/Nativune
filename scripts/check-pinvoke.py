"""Checks that every [DllImport] in src/ names an entry point its Windows DLL actually exports.

A wrong name only fails when that code path runs (EntryPointNotFoundException), e.g. PostMessage
declared with ExactSpelling = true: user32.dll exports only PostMessageA/PostMessageW.
Usage: python scripts/check-pinvoke.py   (exit 1 on a missing entry point)
"""
import glob
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYSTEM32 = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32")

ATTRIBUTE = re.compile(
    r"\[(?:System\.Runtime\.InteropServices\.)?DllImport\((?P<args>[^\]]*)\)\]"
    r"(?:\s*\[[^\]]*\])*"
    r"\s*(?:(?:private|internal|public|protected|static|extern|unsafe|new)\s+)+"
    r"[\w<>\[\],.?\s]+?\s+(?P<name>\w+)\s*\(",
    re.S,
)


def exports(path):
    with open(path, "rb") as f:
        data = f.read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)
    export_rva = struct.unpack_from("<I", data, directories)[0]
    if export_rva == 0:
        return set()
    table = optional + optional_size
    spans = [struct.unpack_from("<IIII", data, table + 40 * i + 8) for i in range(sections)]

    def offset(rva):
        for size, address, _, raw in spans:
            if address <= rva < address + max(size, 1):
                return rva - address + raw
        raise ValueError(f"RVA {rva:#x} outside sections in {path}")

    export = offset(export_rva)
    count, names = struct.unpack_from("<I", data, export + 24)[0], struct.unpack_from("<I", data, export + 32)[0]
    result = set()
    for i in range(count):
        start = offset(struct.unpack_from("<I", data, offset(names) + 4 * i)[0])
        result.add(data[start:data.index(b"\0", start)].decode("ascii"))
    return result


def dll_path(name):
    file = name if name.lower().endswith(".dll") else name + ".dll"
    if file.lower() == "comctl32.dll":
        # TaskDialog and other v6 exports live in the side-by-side Common Controls 6 assembly.
        candidates = sorted(glob.glob(os.path.join(
            os.environ.get("SystemRoot", r"C:\Windows"), "WinSxS",
            "amd64_microsoft.windows.common-controls_6595b64144ccf1df_6.0.*", "comctl32.dll")))
        if candidates:
            return candidates[-1]
    path = os.path.join(SYSTEM32, file)
    return path if os.path.isfile(path) else None


def argument(args, key):
    match = re.search(key + r"\s*=\s*([^,)]+)", args)
    return match.group(1).strip() if match else None


def main():
    cache, failures, skipped, checked = {}, [], set(), 0
    for source in sorted(glob.glob(os.path.join(ROOT, "src", "**", "*.cs"), recursive=True)):
        text = open(source, encoding="utf-8-sig").read()
        for match in ATTRIBUTE.finditer(text):
            args = match.group("args")
            dll = re.match(r'\s*"([^"]+)"', args).group(1)
            entry = (argument(args, "EntryPoint") or match.group("name")).strip('"')
            if entry.startswith("#"):
                continue
            path = dll_path(dll)
            if path is None:
                skipped.add(dll)
                continue
            names = cache.setdefault(path, exports(path))
            exact = (argument(args, "ExactSpelling") or "false") == "true"
            unicode = (argument(args, "CharSet") or "").endswith("Unicode")
            accepted = [entry] if exact else [entry, entry + ("W" if unicode else "A")]
            checked += 1
            if not any(name in names for name in accepted):
                line = text.count("\n", 0, match.start()) + 1
                hint = [n for n in (entry + "W", entry + "A") if n in names]
                failures.append(f"{os.path.relpath(source, ROOT)}:{line}: {dll}!{entry} not exported"
                                + (f" (exports {', '.join(hint)}; drop ExactSpelling or set EntryPoint)" if hint else ""))
    for failure in failures:
        print("FAIL:", failure)
    note = f"; not found on this PC (unchecked): {', '.join(sorted(skipped))}" if skipped else ""
    print(("FAIL" if failures else "PASS") + f": {checked} DllImport entry points checked{note}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
