# OpenSA2 on iPhone and iPad

The iOS port runs the same recompiled game, runtime, renderer and touch controls as the Android app, in one iOS app you build on a Mac and install on your own device. It needs your own copy of the 2012 PC release of *Sonic Adventure 2*, exactly as the other platforms do. The app holds no game file: you copy your game folder onto the device, and the app verifies it before it plays.

**Status: experimental, running on a device.** The port has been built on a Mac and played on a recent iPhone (an A20 Pro, iOS 27.2): the title, a full Hero story stage and Chao World at a steady 60 frames a second at the screen's own resolution, using about 1–1.4 GB of memory, with no draw or shader failure. A Bluetooth controller works too. Other devices and iPad have not been tried yet. Read [current limitations](status.md) for the game itself, and [What is not verified](#what-is-not-verified) below for the port.

## How it differs from Android

Every other platform runs the game as a process of its own beside the player. iOS lets an app start no other program, so three things change:

- **The game is a thread of the app.** `tools/s9/ios_game.py` prelinks the lifted image, the runtime, the hooks and the driver into one library whose only global symbols are the game's four entry points (`host/ios/native/sa2_ios_game.h`). The game's `exit`, `_exit` and `atexit` are renamed at compile time so the game's end ends its thread, not the app. A SIGTERM's stop becomes a function call (`sa2_dinput_request_stop`). The runtime keeps its state in globals, so **a game runs once per app launch**: quit the app and open it again to play again.
- **The renderer draws with Metal.** SDL_gpu has no Vulkan on iOS. The renderer (`host/d3d9gpu`) makes SDL_gpu's Metal device and converts each SPIR-V shader it builds to the Metal shading language with SDL_shadercross and SPIRV-Cross (`host/player/sa2_gpu_shader.h`). With no Vulkan device to read DXVK's facts from, the shader translator uses its most conservative profile, the one Vulkan 1.1 drivers take. DXT textures fall back to the CPU decoder and D24S8 to D32S8 where the GPU lacks them, as on Android.
- **Apple's linker has no `--wrap`.** The runtime's wraps of lifted functions are made on the objects before the link (`tools/s9/macho_wrap.py`), redirecting exactly the references GNU ld's `--wrap` redirects.

The relay, the pacing, the stream contract, the touch overlay, the settings, the tweaks and the session records are the Android session's (`host/ios/native/sa2_ios_session.mm` follows `host/android/native/sa2_android_session.cpp` step by step).

## What you need

- A Linux build machine that can already build the game for Android: the analyzed executable, the translated modules, DXVK's build and the other inputs under `private/` ([the developer guide](getting-started.md)). The iOS build reuses those inputs.
- A Mac with Xcode 16 or later, and from Homebrew: `cmake`, `ninja`, `llvm@20`, `gpatch` (GNU patch, for SDL3's patches; macOS's own `patch` is Apple's), `python@3.13` and, if pip finds no wheel for `iced-x86`, `rust`. The lifted modules are LLVM 20 IR, which Xcode's own clang cannot read.
- Python 3.10 or later with the checkout's requirements in `.venv`. The `python3` Xcode installs is 3.9, which the requirements' pins refuse, so make the environment with Homebrew's: `/opt/homebrew/bin/python3.13 -m venv .venv && .venv/bin/python -m pip install --upgrade pip && .venv/bin/python -m pip install -r requirements.txt`.
- An iPhone or iPad on iOS 15 or later. More memory is better: see [What is not verified](#what-is-not-verified). A free Apple account can sign the app for seven days at a time; a sideloading tool such as AltStore or SideStore can install and refresh it. The game is compiled ahead of time, so the app needs no JIT and no special entitlement.

## Build it

1. On the Linux machine, build the Android game's inputs as usual (`tools/s3/whole_image/lift_all.py`, `tools/s4/rebuild_image.py`, `tools/s5/build_host_deps.sh`, and `tools/s7/release_build.py --only tables` for the overlay table).

2. Compile the lifted image for iOS. This step needs only an LLVM 20 clang, so it can run on the Linux machine (it takes as long as the Android compile):

   ```bash
   .venv/bin/python tools/s9/ios_game.py compile --clang /usr/lib/llvm-20/bin/clang --jobs 8
   ```

   Build the code-patch tweaks for those objects too (`no-music`, `no-voices`, `spin-dash-fast`, `stage-select-all`, `victory-powerups`). On Linux `nm` must be LLVM's, since GNU nm reads no Mach-O object; on the Mac its own `nm` does:

   ```bash
   SA2_NM=llvm-nm-20 .venv/bin/python tools/s8/variants/variants.py build \
       --objects private/generated/s9/ios/objects-double --out private/generated/s9/ios/variants
   ```

3. Copy the checkout, `private/` included, to the Mac. Keep the same relative layout; absolute paths in DXVK's compile commands are moved onto the new checkout by the build. DXVK's source must arrive as a git checkout at its pinned commit (the shader translator's build reads its commit), so copy its `.git` too, or clone it again on the Mac:

   ```bash
   rsync -a --info=progress2 OpenSA2/ mac:OpenSA2/
   # or, on the Mac, when private/s5-tools/src/dxvk-3.1.1 came without its .git:
   rm -rf private/s5-tools/src/dxvk-3.1.1
   git clone --branch v3.1.1 --recurse-submodules https://github.com/doitsujin/dxvk.git private/s5-tools/src/dxvk-3.1.1
   ```

   The libpng tarball the app's dependencies use is under `private/predecessor-tools/win-deps/`; fetch it on the Mac if the Linux machine could not (`curl -fL -o private/predecessor-tools/win-deps/libpng-1.6.59.tar.xz https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz`).

4. On the Mac, link the game (the runtime is compiled for the iOS SDK here):

   ```bash
   .venv/bin/python tools/s9/ios_game.py link --llvm /opt/homebrew/opt/llvm@20/bin \
       --variants private/generated/s9/ios/variants
   ```

   Without `--variants` the game links without the code-patch tweaks: the Tweaks screen still lists them, and the game's log names each one it was built without. It writes `private/generated/s9/ios/game/libsa2game.a` and prints `IOS_GAME_OK`.

5. Build the app's libraries and its Xcode project:

   ```bash
   .venv/bin/python tools/s9/ios_app.py --team YOURTEAMID
   ```

   This builds zlib, libpng, zstd, the patched SDL3, SPIRV-Cross and SDL_shadercross, the shader translator, the renderer, the player, the relay and the installer as static libraries, writes the app's resources, and generates `private/generated/s9/ios/xcode/SA2Recomp.xcodeproj`. Leave out `--team` to choose a team in Xcode instead.

6. Open the project in Xcode, choose your device, and run. Or make an unsigned `.ipa` for a sideloading tool to sign:

   ```bash
   .venv/bin/python tools/s9/ios_app.py --only ipa
   ```

   The file is `private/generated/s9/ios/SA2Recomp.ipa`.

Without a game library, `ios_app.py` still builds the app with a stand-in that refuses to start a game. That build checks everything else, and its renderer check can play a recorded stream.

## Put the game on the device

1. Open the app once, so its folder appears in the Files app.
2. Copy your *Sonic Adventure 2* folder (the one that holds `sonic2app.exe` and `resource/`) into **On My iPhone › SA2 Recompiled › Game**, with the Files app, AirDrop, or a Mac's Finder (the device's Files tab). About 3 GB.
3. In the app, tap **Verify the game in the Game folder**. The installer checks every file the game reads against the same table the other platforms use and writes nothing into the game folder.

You can also choose a folder elsewhere (an external drive, for example) or install from a ZIP of the game folder. A ZIP is extracted into the app's own data, so it needs the space twice while it installs.

Saves and the game's configuration live in the app's own data, never in the game folder. **Saves** exports them to the app's folder in the Files app and imports a folder of save files.

## Play

- **Touch controls** appear at the first touch: a floating stick on the left, A, B, X and Y on the right, START at the top centre, LT and RT in the top corners. **Touch and controllers** changes their size and opacity, moves them (a layout editor for landscape and one for portrait), and changes what each button sends.
- **Controllers.** Any controller iOS pairs (Xbox, PlayStation, Switch Pro, MFi) is a gamepad to the game. Pressing one of its buttons hides the touch controls until the next touch.
- **The in-game menu** opens from the small button below START, or a tap with three fingers anywhere. It turns the debug overlay on or off, copies the session's folder path, or ends the session. The game keeps running behind it: pause with START first.
- **Leaving the app** pauses the game and its sound, and both continue where they were when you come back (the `pause-unfocused` tweak, always on here: iOS refuses GPU work from an app in the background).
- **Display and speed** has the Android app's choices: orientation, widescreen, aspect, resolution, the HUD at 4:3, and the low-FPS speed fix. **Tweaks** has every tweak the other platforms have.

## Debugging

Everything a bug report needs stays on the device, in the app's folder in the Files app:

- **Sessions/**: one folder for each of the last five sessions, with `report.txt` (what the session decided and how it ended), `console.log` (everything the game, the player and SDL printed), `session-info.json` (the device, the app's version, the settings), and the records the desktop launcher keeps (`game.runrec`, `player-report.runrec`, `d3d9gpu.runrec`, `counts.runrec`, `input.log`, `ticks.tsv`). The **Debug** screen reads each file and shares a session as a ZIP.
- **A crash**: a session the app did not come back from is reported on the next launch, with its log.
- **Record sessions** adds the saves and configuration before and after, and the pads' log.
- **The debug overlay** shows the console's last lines and the frames the relay handed on, over the game, without taking touches.
- **game.env.extra** in the app's folder (or the Debug screen's editor) holds `SA2_` lines that replace the session's own settings, as on Android: `SA2_PLAY_RES=h720`, `SA2_D3D9GPU_NO_BC=1`, `SA2_TOUCH_CONTROLS=0`.
- **Renderer switches**: DXT decoded on the CPU, and SDL_gpu's debug mode.
- **Renderer check**: play a recorded stream (`.sa2s`) through the player with no game.
- **Logs**: `app.log` (this launch) and `app.previous.log`. Every line also goes to the unified log, so Xcode's console and Console.app show them while the device is connected.
- **Speed and memory**: every 30 seconds the report has a `perf:` line (frames a second, thermal state, the app's memory and how much more iOS allows), and `mem.tsv` in the session folder has the memory every second, with Metal's and malloc's parts. Two heavier probes are off unless a line in **game.env.extra** turns them on: `SA2_IOS_PROF=1` samples every thread's stack a hundred times a second and writes where the time went to `prof.txt`; `SA2_IOS_MEMWATCH=1` samples memory five times a second and writes `mem-big.txt`, every allocation of 32 MiB or more with its call stack and, at each jump of the footprint, what it is made of. When iOS ends the app for its memory, it often leaves no crash report: look for a **JetsamEvent** under Settings › Privacy & Security › Analytics & Improvements › Analytics Data, and at the end of `mem.tsv`.
- **Under Xcode's debugger**, the scheme's lldb init file (`host/ios/lldbinit`) passes the faults the runtime handles itself through to it, so a session plays as it does without the debugger.

## Where things are

| Path | What |
| --- | --- |
| `host/ios/native/` | The app's native side: `main`, the in-process session, the console capture, the in-game menu, and the game's thread (`sa2_ios_game.c`, linked into the game library). |
| `host/ios/app/` | The Swift screens: setup, settings, controls and their layout editor, tweaks, saves, debug and the session report. |
| `host/ios/CMakeLists.txt` | The Xcode project, generated by `tools/s9/ios_app.py`. |
| `host/player/sa2_gpu_shader.h` | SPIR-V to MSL for a Metal device (the renderer's and the touch overlay's shaders). |
| `host/d3d9gpu/d9g_gpu_sdl.cpp` | `make_metal_gpu`: the Metal device and its shader profile. |
| `runtime/sa2_trap.c` | The trap backend's Darwin pieces (signal context, image bounds, thread names). |
| `tools/s9/ios_game.py` | The game library: the lifted image for arm64-apple-ios, the runtime, the wraps and the prelink. |
| `tools/s9/ios_app.py` | Every other library, the resources, the Xcode project and the `.ipa`. |
| `tools/s9/macho_wrap.py` | GNU ld's `--wrap` made on Mach-O objects. |

## What is not verified

What the first device sessions found and fixed, so that a regression is recognised:

- **Darwin's `poll()` on the stream FIFO** reported nothing while the game sat blocked in a write to it, so every wait ran to its timeout and the game ran at 1–2 frames a second with every thread idle. The session's waits on its pipes go through `select()` on Apple platforms (`host/sa2_poll_select.h`).
- **SDL_gpu's Metal backend** keeps every buffer it makes when a mapped transfer buffer is cycled while still marked in use, and it marks one idle only at a later submit. The renderer's 64 MB upload ring, cycled each frame, grew by gigabytes at each scene change until iOS ended the app. On Metal the renderer keeps four ring buffers and picks an idle one itself (`host/d3d9gpu/d9g_gpu_sdl.cpp`, `kMetalRings`).
- **Metal's vertex layouts** abort the app on a stride of 0 at a per-instance rate (DXVK's dummy binding); the renderer gives it stride 16 there, and refuses any other layout Metal would abort on by name.
- **SDL without Vulkan** leaves `SDL_Vulkan_GetInstanceExtensions`'s hook null on UIKit; the player skips the Vulkan checks before CreateDevice on iOS.

Still not verified:

- **Other devices.** Only one recent iPhone (an A20 Pro) has run the game. The app's footprint is about 1–1.4 GB, well inside a recent iPhone's limit; older devices with less memory are untried. `-DSA2_IOS_INCREASED_MEMORY=ON` (a paid team's entitlement) raises the limit where iOS allows.
- **Every shader through SPIRV-Cross.** Every shader of a story stage and Chao World converted and drew; the rest of the game's stages have not been played.
- **The touch layout editor, iPad, saves import and export, the installer's ZIP route** on a device, and folders chosen outside the app's own. (A Bluetooth controller has been played with.)

Report what you find with a session's ZIP (Debug › Session folders › Share), keeping game data out of public issues as [CONTRIBUTING.md](../CONTRIBUTING.md) asks.
