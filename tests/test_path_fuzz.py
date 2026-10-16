"""Property/fuzz-style tests for path confinement on a real Windows machine.

Invariants, for every input we can think of:
  * resolve_allowed either raises ActionError or returns a path inside the root;
    it never raises anything else.
  * File actions never read, list, copy from/to or create anything outside the root.
"""
import ctypes
import os
import random
import subprocess
import sys

import pytest

from agent.actions import REGISTRY, ActionError, Context, resolve_allowed, validate_params
from agent.screenshots import NAME_RE

WINDOWS = sys.platform == "win32"


@pytest.fixture
def world(tmp_path):
    root = tmp_path / "root"
    (root / "sub" / "deeper").mkdir(parents=True)
    (root / "a.txt").write_text("inside")
    outside = tmp_path / "outside_secret_dir"
    outside.mkdir()
    (outside / "secret.txt").write_text("TOP SECRET")
    sibling = tmp_path / "root_evil"                 # shares the root's name as a prefix
    sibling.mkdir()
    (sibling / "x.txt").write_text("prefix trap")
    return root, outside, sibling


def _plain(p) -> str:
    s = os.path.normcase(os.path.normpath(str(p)))
    return s[4:] if s.startswith("\\\\?\\") else s


def inside(path, root) -> bool:
    p, r = _plain(path.resolve()), _plain(root.resolve())
    return p == r or p.startswith(r + os.sep)


def snapshot(base):
    out = set()
    for dirpath, dirs, files in os.walk(base):
        for n in dirs + files:
            out.add(os.path.join(dirpath, n))
    return out


# --------------------------------------------------------------- fixed attack list
def attacks(root, outside, sibling):
    r, o, s = str(root), str(outside), str(sibling)
    drive = os.path.splitdrive(r)[0] or "C:"
    return [
        o, os.path.join(o, "secret.txt"), s, os.path.join(s, "x.txt"),
        r + "\\..\\outside_secret_dir", r + "/../outside_secret_dir/secret.txt",
        r + "\\sub\\..\\..\\outside_secret_dir", r + "\\" + "..\\" * 12 + "Windows",
        r + "\\sub\\deeper\\..\\..\\..\\root_evil",
        r + "_evil", r + "evil", r.upper() + "_EVIL",
        "..", "..\\..", ".", "", " ", "\x00", r + "\x00.txt", r + "\\a.txt\x00..\\..",
        # alternate data streams
        r + "\\a.txt:hidden", r + "\\a.txt::$DATA", r + "\\sub::$INDEX_ALLOCATION",
        r + "\\sub:stream:$DATA", r + "\\:evil",
        # reserved device names
        r + "\\CON", r + "\\nul", r + "\\NUL.txt", r + "\\com1", r + "\\Com9.log",
        r + "\\LPT1", r + "\\aux", r + "\\prn.txt", r + "\\sub\\CON\\x", r + "\\con ", r + "\\nul.",
        # trailing dots/spaces
        r + "\\sub.", r + "\\sub ", r + "\\sub. .", r + "\\sub...\\..\\..\\outside_secret_dir",
        r + "\\a.txt.", r + "\\a.txt ", r + "\\ sub",
        # UNC / extended / device paths
        "\\\\localhost\\" + drive[0] + "$\\Windows", "\\\\127.0.0.1\\C$\\Windows\\win.ini",
        "\\\\?\\" + o, "\\\\?\\" + os.path.join(o, "secret.txt"), "\\\\?\\C:\\Windows",
        "\\\\?\\UNC\\localhost\\C$\\Windows", "\\\\.\\C:\\Windows", "\\\\.\\PhysicalDrive0",
        "\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1", "//?/" + o.replace("\\", "/"),
        "\\\\server\\share\\x", "//server/share/x",
        # drive-relative and rooted-without-drive
        drive + "secret.txt", drive + "outside_secret_dir", drive + "..\\x",
        "\\Windows", "/Windows/win.ini", "\\Users",
        # env/home expansion, wildcards
        "~", "~\\", "%USERPROFILE%", "%SystemRoot%\\win.ini", "$HOME", r + "\\*", r + "\\?.txt",
        r + "\\<>", r + '\\"quoted"', r + "\\a|b",
        # mixed separators and case
        r.replace("\\", "/") + "/sub/../../outside_secret_dir", r.upper() + "\\..\\OUTSIDE_SECRET_DIR",
        r.lower() + "\\\\\\sub\\\\..\\\\..\\\\outside_secret_dir",
        # unicode tricks
        r + "\\\u202esub", r + "\\sub\u200b", r + "\\\uff0e\uff0e\\outside_secret_dir",
        r + "\\\u2025\\outside_secret_dir", r + "\\%2e%2e\\outside_secret_dir",
    ]


def test_fixed_attack_list_never_escapes(world):
    root, outside, sibling = world
    for raw in attacks(root, outside, sibling):
        try:
            p = resolve_allowed(raw, [root])
        except ActionError:
            continue
        except Exception as exc:                       # anything else is a bug
            pytest.fail(f"{raw!r} raised {type(exc).__name__}: {exc}")
        assert inside(p, root), f"{raw!r} escaped to {p}"
        assert ":" not in str(p.relative_to(root.resolve())), raw
        parts = [x.split(".")[0].strip().upper() for x in p.relative_to(root.resolve()).parts]
        assert not set(parts) & {"CON", "PRN", "AUX", "NUL", "COM1", "LPT1"}, raw


@pytest.mark.parametrize("ok", ["a.txt", "sub", "sub/deeper", "sub\\deeper", "./a.txt",
                                "sub/../a.txt", "new_dir/file.txt"])
def test_legit_paths_still_work(world, ok):
    root, _, _ = world
    assert inside(resolve_allowed(str(root / ok), [root]), root)


def test_root_itself_and_mixed_case_root(world):
    root, _, _ = world
    assert resolve_allowed(str(root), [root]) == root.resolve()
    if WINDOWS:
        assert inside(resolve_allowed(str(root).swapcase() + "\\sub", [root]), root)


def test_no_roots_means_nothing_is_allowed(world):
    root, _, _ = world
    with pytest.raises(ActionError):
        resolve_allowed(str(root), [])


# ---------------------------------------------------------------------- random fuzz
TOKENS = ["..", ".", "sub", "deeper", "a.txt", "CON", "nul", "com1", "LPT2", "aux.txt",
          "a.txt:s", "::$DATA", ":", "sub.", "sub ", " ", "...", "outside_secret_dir",
          "root_evil", "secret.txt", "\\\\?\\", "\\\\.\\", "C:", "C:x", "~", "%TEMP%",
          "*", "?", "\u202e", "\x00", "PROGRA~1", "DOCUME~1", "a" * 300, "$Recycle.Bin",
          "System Volume Information", "\\\\localhost\\C$"]
SEPS = ["\\", "/", "\\\\", "/\\", "", " ", "\\.\\"]


def random_path(rng, root):
    base = rng.choice([str(root), str(root).replace("\\", "/"), str(root).upper(), "", "."])
    parts = [rng.choice(TOKENS) for _ in range(rng.randint(1, 7))]
    out = base
    for part in parts:
        out += rng.choice(SEPS) + part
    return out


def test_random_paths_never_escape_and_never_crash(world):
    root, outside, sibling = world
    rng = random.Random(20261016)
    allowed_count = 0
    for _ in range(4000):
        raw = random_path(rng, root)
        try:
            p = resolve_allowed(raw, [root])
        except ActionError:
            continue
        except Exception as exc:
            pytest.fail(f"{raw!r} raised {type(exc).__name__}: {exc}")
        allowed_count += 1
        assert inside(p, root), f"{raw!r} escaped to {p}"
        rel = p.relative_to(root.resolve())
        assert ":" not in str(rel)
        assert not {x.split(".")[0].strip().upper() for x in rel.parts} & {"CON", "NUL", "AUX", "PRN"}
    assert allowed_count > 50          # the generator also produces plenty of legal paths


def test_actions_never_touch_anything_outside_the_root(engine, world, settings):
    """Run every path-taking action with fuzzed input; the tree outside stays identical."""
    root, outside, sibling = world
    settings.allowed_roots = [root]
    settings.screenshots_dir = root / "Screens"
    watch = [outside, sibling]
    top_before = set(os.listdir(root.parent)) - {"data"}
    before_outside = set().union(*(snapshot(d) for d in watch))
    contents = {p: open(p, "rb").read() for p in before_outside if os.path.isfile(p)}
    rng = random.Random(7)
    for _ in range(200):
        raw = random_path(rng, root)
        for name, params in (("list_files", {"path": raw}),
                             ("find_files", {"root": raw, "query": "secret"}),
                             ("make_folder", {"path": raw}),
                             ("copy_file", {"src": raw, "dst": random_path(rng, root)}),
                             ("copy_file", {"src": str(root / "a.txt"), "dst": raw})):
            if "\x00" in raw:
                continue
            res = engine.run(name, params, actor="fuzz", via="http")
            if res.ok and name == "list_files":
                assert inside(__import__("pathlib").Path(res.data["path"]), root)
            if res.ok and name == "find_files":
                assert all(inside(__import__("pathlib").Path(m), root) for m in res.data["matches"])
    after_outside = set().union(*(snapshot(d) for d in watch))
    assert after_outside == before_outside
    assert set(os.listdir(root.parent)) - {"data"} == top_before
    assert {p: open(p, "rb").read() for p in after_outside if os.path.isfile(p)} == contents
    assert (outside / "secret.txt").read_text() == "TOP SECRET"


def test_param_validation_rejects_nulls_and_giant_values():
    for name in ("list_files", "make_folder", "copy_file", "find_files", "tail_log", "open_url"):
        spec = REGISTRY[name]
        for bad in ("\x00", "x" * 501):
            params = {p: bad for p in spec.params}
            with pytest.raises(ActionError):
                validate_params(spec, params)
        with pytest.raises(ActionError):
            validate_params(spec, {p: ["list"] for p in spec.params})        # not a string


# ------------------------------------------------------ named-capability actions
def test_names_that_are_not_allowlisted_never_resolve(engine, settings, opened):
    rng = random.Random(3)
    junk = ["..\\..\\Windows\\win.ini", "C:\\Windows\\win.ini", "coder\\..\\..\\x", "coder\x00",
            "CODER/", "coder:stream", "coder.", "\\\\?\\C:\\Windows", "con", "nul"]
    junk += ["".join(rng.choice("abcXYZ./\\: ~$%") for _ in range(12)) for _ in range(200)]
    for name in junk:
        if name.strip().lower() in ("coder",):
            continue
        for action in ("tail_log", "open_app", "run_script"):
            res = engine.run(action, {"name": name}, actor="fuzz", via="http")
            assert not res.ok, (action, name)
    for url in ["https://example.com.evil.com/", "https://evil.com\\@example.com/",
                "https://example.com@evil.com/", "http://example.com/", "file:///C:/Windows/win.ini",
                "https://example.com:8443/", "https://EXAMPLE.com/\u202e", "javascript:alert(1)",
                "https://example.com./", "//example.com/", "https://exam\u0430ple.com/",
                "https://example.com\x00.evil.com/", "https://example.com%2f@evil.com/"]:
        res = engine.run("open_url", {"url": url}, actor="fuzz", via="http")
        assert not res.ok, url
    assert opened == []


def test_screenshot_names_are_a_closed_pattern():
    good = ["screenshot-20261016-101500.png", "screenshot-20261016-101500-2.jpg"]
    assert all(NAME_RE.fullmatch(g) for g in good)
    bad = ["..\\x.png", "screenshot-20261016-101500.png:stream", "screenshot-20261016-101500.png.",
           "screenshot-20261016-101500.png ", "/screenshot-20261016-101500.png",
           "screenshot-20261016-101500.png\n", "SCREENSHOT-20261016-101500.png",
           "screenshot-20261016-101500.PNG", "screenshot-2026101-101500.png",
           "screenshot-20261016-101500.png\x00.txt", "C:screenshot-20261016-101500.png",
           "screenshot-20261016-101500.png/..", "screenshot-\u0662\u0660261016-101500.png"]
    for b in bad:
        assert not NAME_RE.fullmatch(b), b


# ------------------------------------------------------------- Windows-only tricks
needs_windows = pytest.mark.skipif(not WINDOWS, reason="Windows-only path semantics")


def _short_name(path) -> str | None:
    buf = ctypes.create_unicode_buffer(520)
    n = ctypes.windll.kernel32.GetShortPathNameW(str(path), buf, 520)
    return buf.value if n else None


@needs_windows
def test_8_3_short_names_resolve_to_the_long_name(world):
    root, outside, _ = world
    short = _short_name(outside)
    if not short or short.lower() == str(outside).lower():
        pytest.skip("8.3 short names are disabled on this volume")
    with pytest.raises(ActionError):                  # alias of an outside folder
        resolve_allowed(short, [root])
    with pytest.raises(ActionError):
        resolve_allowed(os.path.join(short, "secret.txt"), [root])
    short_root = _short_name(root)
    if short_root:                                    # alias of the root itself is fine
        assert inside(resolve_allowed(short_root + "\\sub", [root]), root)


@needs_windows
def test_junction_out_of_the_root_is_refused_everywhere(engine, world, settings):
    root, outside, _ = world
    link = root / "link"
    proc = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)],
                          capture_output=True, text=True)
    if proc.returncode != 0 or not link.exists():
        pytest.skip(f"cannot create a junction here ({proc.stdout.strip()[:60]})")
    settings.allowed_roots = [root]
    settings.screenshots_dir = root / "Screens"
    for raw in (str(link), str(link / "secret.txt"), str(link / "new"), str(link) + "\\..\\a.txt"):
        if raw.endswith("a.txt"):
            continue                                   # lexical ".." resolves back inside: fine
        with pytest.raises(ActionError):
            resolve_allowed(raw, [root])
    assert not engine.run("list_files", {"path": str(link)}, "fuzz", "http").ok
    assert not engine.run("make_folder", {"path": str(link / "pwned")}, "fuzz", "http").ok
    assert not (outside / "pwned").exists()
    assert not engine.run("copy_file", {"src": str(link / "secret.txt"),
                                        "dst": str(root / "stolen.txt")}, "fuzz", "http").ok
    assert not (root / "stolen.txt").exists()
    assert not engine.run("copy_file", {"src": str(root / "a.txt"),
                                        "dst": str(link / "dropped.txt")}, "fuzz", "http").ok
    assert not (outside / "dropped.txt").exists()
    found = engine.run("find_files", {"root": str(root), "query": "secret"}, "fuzz", "http")
    assert found.ok and found.data["matches"] == []     # the walker does not enter the junction
    subprocess.run(["cmd", "/c", "rmdir", str(link)], capture_output=True)   # removes the link only
    assert (outside / "secret.txt").exists()


@needs_windows
def test_junction_chain_inside_to_outside_via_second_hop(engine, world, settings):
    root, outside, _ = world
    hop = root.parent / "hop"
    hop.mkdir()
    p1 = subprocess.run(["cmd", "/c", "mklink", "/J", str(hop / "toout"), str(outside)],
                        capture_output=True, text=True)
    p2 = subprocess.run(["cmd", "/c", "mklink", "/J", str(root / "viahop"), str(hop)],
                        capture_output=True, text=True)
    if p1.returncode or p2.returncode:
        pytest.skip("cannot create junctions here")
    try:
        with pytest.raises(ActionError):
            resolve_allowed(str(root / "viahop" / "toout" / "secret.txt"), [root])
    finally:
        subprocess.run(["cmd", "/c", "rmdir", str(root / "viahop")], capture_output=True)
        subprocess.run(["cmd", "/c", "rmdir", str(hop / "toout")], capture_output=True)


@needs_windows
def test_components_with_trailing_dots_or_spaces_are_refused(world):
    """Windows silently drops trailing dots/spaces, so 'sub .' and 'sub' are the same
    folder to the OS but different strings to us. Refuse the ambiguity outright."""
    root, _, _ = world
    for rel in ("sub .", "sub ", "sub.", "sub ...\\x", "sub. \\deeper", "new. \\x", ".. ", ".. .",
                "sub\\.. \\x"):
        with pytest.raises(ActionError):
            resolve_allowed(str(root) + "\\" + rel, [root])
    # a name that merely contains dots or spaces inside is fine
    assert inside(resolve_allowed(str(root / "my file.v2.txt"), [root]), root)
