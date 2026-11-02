# OpenSA2 on iPhone and iPad

The iOS port runs the same recompiled game, runtime, renderer and touch controls as the Android app, in one iOS app you build on a Mac and install on your own device. It needs your own copy of the 2012 PC release of *Sonic Adventure 2*, exactly as the other platforms do. The app holds no game file: you copy your game folder onto the device, and the app verifies it before it plays.

**Status: experimental, running on a device.** The port has been built on a Mac and played on a recent iPhone (an A20 Pro, iOS 27.2): the title, a full Hero story stage and Chao World at a steady 60 frames a second at the screen's own resolution, using about 1–1.4 GB of memory, with no draw or shader failure. A Bluetooth controller works too. Other devices and iPad have not been tried yet. Read [current limitations](status.md) for the game itself, and [What is not verified](#what-is-not-verified) below for the port.

## How it differs from Android

Every other platform runs the game as a process of its own beside the player. iOS lets an app start no other program, so three things change:

- **The game is a thread of the app.** `tools/s9/ios_game.py` prelinks the lifted image, the runtime, the hooks and the driver into one library whose only global symbols are the game's four entry points (`host/ios/native/sa2_ios_game.h`). The game's `exit`, `_exit` and `atexit` are renamed at compile time so the game's end ends its thread, not the app. A SIGTERM's stop becomes a function call (`sa2_dinput_request_stop`). The runtime keeps its state in globals, so **a game runs once per app launch**: quit the app and open it again to play again.
- **The renderer draws with Metal.** SDL_gpu has no Vulkan on iOS. The renderer (`host/d3d9gpu`) makes SDL_gpu's Metal device and converts each SPIR-V shader it builds to the Metal shading language with SDL_shadercross and SPIRV-Cross (`host/player/sa2_gpu_shader.h`). With no Vulkan device to read DXVK's facts from, the shader translator uses its most conservative profile, the one Vulkan 1.1 drivers take. DXT textures fall back to the CPU decoder and D24S8 to D32S8 where the GPU lacks them, as on Android.
- **Apple's linker has no `--wrap`.** The runtime's wraps of lifted functions are made on the objects before the link (`tools/s9/macho_wrap.py`), redirecting exactly the references GNU ld's `--wrap` redirects.

The relay, the pacing, the stream contract, the touch overlay, the settings, the tweaks and the session records are the Android session's (`host/ios/native/sa2_ios_session.mm` follows `host/android/native/sa2_android_session.cpp` step by step).

## Build it

To play, you only need the `.ipa` and your game folder: if someone has published a build, skip to [Put the game on the device](#put-the-game-on-the-device). Building one yourself has two halves:

- **The Linux half** translates the game. It needs your Steam copy's `sonic2app.exe`, about 25 GB of disk and about three and a half hours on a two-core machine (GitHub's runner), and ends in one archive, `mac-inputs.tar.xz` (about 110 MB). `tools/s9/ios_inputs.py` runs all of it.
- **The macOS half** links that into the app with Xcode and makes the unsigned `.ipa`, in about 20 minutes. `tools/s9/ios_mac.sh` runs all of it. Apple's iOS build tools run only on macOS, so this half needs a Mac, yours or one rented by the minute in the cloud.

Neither half has to run on a computer you own. Pick one of these:

| | Linux half | macOS half | What you need |
| --- | --- | --- | --- |
| [A. All in the cloud](#a-all-in-the-cloud-no-computer-of-your-own) | GitHub Actions (Linux) | GitHub Actions (macOS) | A GitHub account and a private repository; a phone or tablet is enough |
| [B. Cloud Linux, your Mac](#b-a-cloud-linux-machine-and-a-mac) | Any Linux machine or cloud VM | Your Mac | How this port was first built |
| [C. Your own machines](#b-a-cloud-linux-machine-and-a-mac) | Your Linux PC | Your Mac | The same commands as B |

Either way, nothing of the game goes into the public repository: the executable and everything translated from it stay under `private/` (ignored) or in your private repository. The `.ipa` itself holds the recompiled game logic and the port's runtime, with no original executable or assets, as upstream's Windows, Android and Linux downloads do.

### Getting `sonic2app.exe`

Every route starts from your Steam copy's `sonic2app.exe` (the 2012 PC release; its sha256 is pinned in `tools/pins.json`), and the device needs the whole game folder (`sonic2app.exe` and `resource/`, about 3 GB).

- **With a Windows PC or a Steam Deck**: Steam's own folder (Steam › Sonic Adventure 2 › Manage › Browse local files).
- **Without one**: Steam will not install a Windows-only game on a Mac, but [DepotDownloader](https://github.com/SteamRE/DepotDownloader) downloads it from any machine, a cloud one included: a [GitHub Codespace](https://github.com/features/codespaces) opens a Linux terminal in a browser, on a phone or tablet too. With your own Steam login (approve it in the Steam app when it asks):

  ```bash
  ./DepotDownloader -app 213610 -os windows -username YOUR_STEAM_NAME -dir SA2
  cd SA2 && zip -r ../SA2.zip . -x '.DepotDownloader/*'   # the whole game folder, for the device
  ```

  Download `SA2/sonic2app.exe` for the build, and `SA2.zip` for the device (the app installs from a ZIP: [Put the game on the device](#put-the-game-on-the-device)).

The Linux half also needs the executable **unpacked by [Steamless](https://github.com/atom0s/Steamless) 3.1.0.5** with its default options (Steam's DRM wrapper hides the code it translates). Steamless is a Windows (.NET) program: route A runs it on a Windows runner for you; otherwise run it on Windows (`Steamless.CLI.exe --quiet sonic2app.exe` writes `sonic2app.exe.unpacked.exe`) and hand that file to `ios_inputs.py`, which renames two of its sections as the pinned copy names them and checks the result against the pin.

### A. All in the cloud (no computer of your own)

GitHub runs all three steps: a Windows runner unpacks the executable, a Linux runner translates the game, a macOS runner builds the `.ipa`. Everything happens in a **private** repository of yours, so the executable and the translated game are never public. All of it can be done from a phone's browser.

1. **Make a private repository** on GitHub (for example `OpenSA2-ios-build`). It only holds the workflow and your executable; the source is checked out from the public repository at each run.
2. **Upload your executable**: in the new repository, **Releases › Create a new release**, tag `game`, attach `sonic2app.exe` (only the executable: the build needs nothing else), and publish it. The repository is private, so the release is too. (Or commit it to the repository as `game/sonic2app.exe`: the workflow takes it from either place.)
3. **Add the workflow**: **Add file › Create new file**, name it `.github/workflows/ios-build.yml`, and paste in [`tools/s9/ci/ios-build.yml`](../tools/s9/ci/ios-build.yml). Commit it.
4. **Run it**: **Actions › SA2 iOS build › Run workflow**. Leave the source as `xBusse/OpenSA2-ios` and `ios-port` (or name your own fork and branch). A run takes about three and a half hours, nearly all of it the Linux job. If only the macOS job fails, **Re-run failed jobs** reuses the Linux job's archive (kept for a day) and takes ten minutes.
5. **Take the `.ipa`**: the run makes a release in your private repository with `SA2Recomp.ipa` attached (and keeps it as the run's artifact for 30 days). Open it on the device with your sideloading tool, or publish it.

Its cost on GitHub's free plan: a private repository gets 2,000 runner minutes a month, macOS minutes count ten times and Windows twice, and one run uses roughly 210 Linux, 10 macOS and 1 Windows minutes: about 320 of the 2,000. If a run stops, the Linux job uploads its logs (`linux-logs`); `ios_inputs.py` names the step and the end of that step's log.

### B. A cloud Linux machine and a Mac

This is how the port was first built: the Linux half in a cloud container, the macOS half on a Mac. A Linux PC of your own does the same.

**The Linux half** (Ubuntu 24.04, x86-64; about 25 GB free, 7 GB of memory, more cores make it faster):

```bash
sudo apt-get install -y clang-20 llvm-20 git curl unzip xz-utils python3-venv
git clone -b ios-port https://github.com/xBusse/OpenSA2-ios.git && cd OpenSA2-ios
python3 -m venv .venv && .venv/bin/python -m pip install -r requirements.txt
.venv/bin/python tools/s9/ios_inputs.py all \
    --exe ~/sonic2app.exe --unpacked ~/sonic2app.exe.unpacked.exe
```

It fetches and checks its own tools (Ghidra, a JDK, Zig, Remill, the Mod Loader's names, DXVK's source; each download is held to the hash it had when this recipe was proven), then analyses the executable, translates and compiles the game for iOS, and writes `private/generated/s9/ios/mac-inputs.tar.xz`. Each step is skipped when its output is there, so a run that stops can be started again; `--force STEP` redoes one, and `.venv/bin/python tools/s9/ios_inputs.py --help` lists the steps. On a small disk add `--prune`, which deletes each stage's raw IR once it is compiled.

**The macOS half** (Xcode 16 or later, [Homebrew](https://brew.sh)): copy `mac-inputs.tar.xz` to the Mac, then

```bash
git clone -b ios-port https://github.com/xBusse/OpenSA2-ios.git && cd OpenSA2-ios
bash tools/s9/ios_mac.sh ~/Downloads/mac-inputs.tar.xz --install-deps
```

`--install-deps` installs what it needs from Homebrew (`cmake`, `ninja`, `llvm@20`, `gpatch`, `python@3.13`); without it, it names what is missing. It makes the `.venv` with Homebrew's Python (Xcode's `python3` is 3.9, which the requirements refuse; if pip then has to build `iced-x86` from source, `brew install rust`), clones DXVK at its pinned commit, fetches libpng if the Linux machine could not, links the game with the code-patch tweaks, builds the app's libraries and Xcode project, and writes `private/generated/s9/ios/SA2Recomp.ipa` (`--out DIR` copies it there). `--team TEAMID` signs the Xcode project for running from Xcode instead.

The steps it runs, for reference: `tools/s9/ios_game.py link --llvm $(brew --prefix llvm@20)/bin --variants private/generated/s9/ios/variants`, then `tools/s9/ios_app.py`, then `tools/s9/ios_app.py --only ipa`.

### Rebuilding after an update

- **The app, the runtime, the renderer or the player changed** (most updates): on the Mac, `git pull && bash tools/s9/ios_mac.sh`. No archive is needed: it reuses the one already unpacked. In the cloud, run the workflow again.
- **The translation changed** (the lift tools, `Documentation/lifted-extras.json`, the f80 pass or the code-patch tweaks' specs): run the Linux half again (`ios_inputs.py all --force ios --force variants`, or `--force` the step that changed and the ones after it), then the Mac half with the new archive.

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
| `tools/s9/ios_inputs.py` | The whole Linux half, step by step, ending in `mac-inputs.tar.xz`. |
| `tools/s9/ios_mac.sh` | The whole macOS half, from that archive to the `.ipa`. |
| `tools/s9/ci/ios-build.yml` | Both halves on GitHub's runners, for a private repository (route A). |
| `tools/s4/lift_extras_listed.py` | The lifted extras rebuilt from `Documentation/lifted-extras.json`, on a machine that never ran the plays they came from. |
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
