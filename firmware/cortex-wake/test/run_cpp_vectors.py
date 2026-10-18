#!/usr/bin/env python3
"""Compile include/cw_auth.h to WebAssembly with clang and run docs/cortex-wake/test_vectors.json
against it with Node. Needs: a clang with the wasm32 target + wasm-ld (the Android NDK has both)
and Node.js. Exit 0 = all vectors pass, 1 = failure, 77 = tools missing (skipped, NOT verified).

    set CW_CLANG_DIR=D:\\AndroidSDK\\ndk\\27.0.12077973\\toolchains\\llvm\\prebuilt\\windows-x86_64\\bin
    python firmware/cortex-wake/test/run_cpp_vectors.py
"""
from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SKIP = 77


def find_clang_dir() -> Path | None:
    env = os.environ.get("CW_CLANG_DIR")
    cands = [Path(env)] if env else []
    for home in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"), r"D:\AndroidSDK"):
        if home:
            cands += [Path(p) for p in glob.glob(
                str(Path(home) / "ndk" / "*" / "toolchains" / "llvm" / "prebuilt" / "*" / "bin"))]
    found = shutil.which("clang")
    if found:
        cands.append(Path(found).parent)
    for c in cands:
        exe = "clang.exe" if os.name == "nt" else "clang"
        wasm = "wasm-ld.exe" if os.name == "nt" else "wasm-ld"
        if (c / exe).exists() and (c / wasm).exists():
            return c
    return None


def main() -> int:
    node = shutil.which("node")
    clang_dir = find_clang_dir()
    if not node or not clang_dir:
        print("SKIPPED: need node and clang+wasm-ld (set CW_CLANG_DIR)", file=sys.stderr)
        return SKIP
    clang = str(clang_dir / ("clang++.exe" if os.name == "nt" else "clang++"))
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "cw_auth.wasm"
        cmd = [clang, "--target=wasm32", "-std=c++17", "-O2", "-nostdlib", "-fno-exceptions", "-fno-rtti",
               "-Wall", "-Wextra", "-Werror", "-fuse-ld=" + str(clang_dir / "wasm-ld"),
               "-Wl,--no-entry"] + [f"-Wl,--export={n}" for n in (
                   "scratch_ptr", "t_hmac", "t_parse", "t_response", "t_led", "t_press_ok")] + [
               str(HERE / "wasm_shim.cpp"), "-o", str(out)]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=420)
        if proc.returncode != 0:
            print("compile failed:\n" + proc.stderr, file=sys.stderr)
            return 1
        run = subprocess.run([node, str(HERE / "run_vectors.mjs"), str(out),
                              str(ROOT / "docs" / "cortex-wake" / "test_vectors.json")],
                             capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
