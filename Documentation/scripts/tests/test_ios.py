"""The iOS port's source-side checks (host/ios, tools/s9): what can be held to the rest of the tree
without a Mac.

  - tools/s9/macho_wrap.py makes GNU ld's -wrap on Mach-O objects: an undefined `X` becomes
    `__wrap_X`, an undefined `__real_X` becomes `X`, with Mach-O's leading underscore, and nothing
    else is touched.
  - tools/s9/ios_app.py's tweaks.json is the Android app's TWEAKS and TWEAK_GROUPS: every tweak once,
    in the Android order, each under the heading the Android Tweaks card shows it under.
  - Its icon is a well-formed RGB PNG (no image is tracked; the build draws it).
  - Its rebase moves the Linux build machine's paths onto the checkout's private/.
  - The game's iOS interface: the prelink's export list is exactly sa2_ios_game.h's functions, and
    the renames ios_game.py compiles the game with name functions sa2_ios_game.c defines.
  - The iOS session sends the player's settings apart as the Android session does (the same names),
    and the Swift settings give a session the SA2_ settings the Android app's do.
  - Every Swift and Objective-C++ file host/ios/CMakeLists.txt lists exists, and every one there is listed.
"""
from __future__ import annotations

import importlib.util
import re
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "s9"))
import macho_wrap as MW  # noqa: E402

IOS = ROOT / "host" / "ios"
GAME_SETTINGS = ROOT / "host/android/java/com/sa2recomp/app/GameSettings.java"


def ios_app():
    spec = importlib.util.spec_from_file_location("ios_app_under_test", ROOT / "tools/s9/ios_app.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_macho_wrap_renames_the_undefined_references_gnu_wrap_redirects():
    undefined = {"_sub_427ee0", "___real_sub_842500", "_sub_999999", "___real_sub_999999", "_memcpy", "sub_427ee0"}
    got = MW.plan(undefined, ["sub_427ee0", "sub_842500"])
    assert got == {"_sub_427ee0": "___wrap_sub_427ee0", "___real_sub_842500": "_sub_842500"}


def test_macho_wrap_leaves_an_object_with_nothing_to_redirect():
    assert MW.plan({"_malloc", "___wrap_sub_427ee0"}, ["sub_427ee0"]) == {}


def test_tweaks_json_is_the_android_catalogue():
    A = ios_app()
    java = GAME_SETTINGS.read_text()
    t = A.tweaks_json(java)
    names = [x["name"] for x in t["order"]]
    java_names = re.findall(r'new Tweak\("([^"]+)"', java[java.index("static final Tweak[] TWEAKS"):])
    assert names == java_names
    grouped = [x["name"] for g in t["groups"] for x in g["tweaks"]]
    assert sorted(grouped) == sorted(names) and len(grouped) == len(set(grouped))
    headings = [g["heading"] for g in t["groups"]]
    assert headings[0] == "Gameplay and assists" and "Other" in headings
    other = next(g for g in t["groups"] if g["heading"] == "Other")
    assert "pause-unfocused" in [x["name"] for x in other["tweaks"]]
    assert all(x["label"] and x["description"] for x in t["order"])


def test_the_icon_is_a_wellformed_rgb_png():
    A = ios_app()
    data = A.icon_png(48)
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    width, height, depth, colour = struct.unpack(">IIBB", data[16:26])
    assert (width, height, depth, colour) == (48, 48, 8, 2)
    at, idat = 8, b""
    while at < len(data):
        n = struct.unpack(">I", data[at:at + 4])[0]
        kind = data[at + 4:at + 8]
        if kind == b"IDAT":
            idat += data[at + 8:at + 8 + n]
        at += 12 + n
    raw = zlib.decompress(idat)
    assert len(raw) == 48 * (1 + 48 * 3)
    # The centre of the ring is the 2's white or the blue; a pixel on the ring is gold.
    row = 24
    ring_x = round(48 / 2 + 27 * 48 / 90)
    px = raw[row * (1 + 144) + 1 + ring_x * 3: row * (1 + 144) + 4 + ring_x * 3]
    assert px[0] > 200 and px[2] < 120


def test_rebase_moves_linux_paths_onto_this_checkout():
    A = ios_app()
    assert A.rebase("/home/user/OpenSA2/private/s5-tools/src/dxvk-3.1.1") == str(ROOT / "private/s5-tools/src/dxvk-3.1.1")
    assert A.rebase("-I/home/user/OpenSA2/private/s5-tools/build/x") == "-I" + str(ROOT / "private/s5-tools/build/x")
    assert A.rebase("-O2") == "-O2"


def test_the_prelink_exports_exactly_the_games_interface():
    header = (IOS / "native/sa2_ios_game.h").read_text()
    declared = set(re.findall(r"^\w[\w ]*?\b(sa2_ios_game_\w+)\(", header, re.M))
    exported = {l.strip()[1:] for l in (IOS / "native/sa2_ios_game.exports").read_text().splitlines() if l.strip()}
    assert declared == exported == {"sa2_ios_game_start", "sa2_ios_game_request_stop", "sa2_ios_game_ended",
                                     "sa2_ios_game_started"}
    nogame = (IOS / "native/sa2_ios_nogame.c").read_text()
    for name in exported:
        assert re.search(rf"\b{name}\(", nogame), name


def test_the_game_renames_name_functions_its_shim_defines():
    spec = importlib.util.spec_from_file_location("ios_game_under_test", ROOT / "tools/s9/ios_game.py")
    G = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(G)
    shim = (IOS / "native/sa2_ios_game.c").read_text()
    for define in G.GAME_DEFINES:
        target = define.split("=", 1)[1]
        assert re.search(rf"\b{target}\(", shim), define
    assert G.MAIN_DEFINES == ("-Dmain=sa2_game_main",)
    assert "sa2_game_main(" in shim
    assert G.ELF_ONLY.match("-fPIC") and G.ELF_ONLY.match("-mcmodel=large") and not G.ELF_ONLY.match("-O2")


def test_the_player_settings_are_the_android_sessions():
    def body(path: Path) -> str:
        text = path.read_text()
        at = text.index("bool player_setting(const std::string& k) {")
        return re.sub(r"\s+", " ", text[at:text.index("}", at)])
    android = body(ROOT / "host/android/native/sa2_android_session.cpp")
    ios = body(IOS / "native/sa2_ios_session.mm")
    assert android == ios


def test_the_swift_settings_send_the_android_apps_settings():
    java = GAME_SETTINGS.read_text()
    swift = (IOS / "app/GameSettings.swift").read_text()
    sent = set(re.findall(r'"(SA2_[A-Z0-9_]+)=', java))
    sent.discard("SA2_ADPF_TARGET_US")              # Android's performance hint session alone
    for name in sent:
        assert f'"{name}=' in swift, name
    # The touch layout's arithmetic: the same constants as the Android editor's.
    for constant in ("0.12", "0.21", "0.075", "0.035", "0.04", "0.09", "0.135", "0.30", "0.60", "1.6"):
        assert constant in swift, constant


def test_the_project_lists_every_app_source():
    cmake = (IOS / "CMakeLists.txt").read_text()
    listed = set(re.findall(r"\b((?:native|app)/[\w.]+\.(?:mm|swift))\b", cmake))
    on_disk = {str(p.relative_to(IOS)) for p in IOS.rglob("*") if p.suffix in (".mm", ".swift")}
    assert listed == on_disk
