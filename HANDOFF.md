# Handoff: Emerge + Solve on the Fairphone 3

Date: 2026-09-29

## Goal

Run a GUI on the FP3 Nerves Livebook firmware with
[Emerge](https://hex.pm/packages/emerge) (declarative UI, Skia + OpenGL ES
on DRM) and [Solve](https://hex.pm/packages/solve) (state controllers),
alongside the existing Scenic setup (notebook 11, fbdev via `cairo-fb`).

## Status

- Firmware builds in place with Emerge 0.4.0 and Solve 0.3.0:
  `_build/nerves_system_fp3_dev/nerves/images/nerves_livebook_fp3.fw`.
- **Not yet run on a phone.** Next step is flashing and running notebook 13.
- Nothing committed. Uncommitted changes in the working tree:
  - `mix.exs`: added `{:emerge, "~> 0.4.0"}` and `{:solve, "~> 0.3.0"}`
    after the Scenic deps.
  - `mix.lock`: added emerge, solve, video_interop; **downgraded
    `rustler_precompiled` 0.9.0 → 0.8.4** (emerge needs `~> 0.8.4`; the only
    other user, `arm_ai`, accepts `~> 0.8`).
  - `config/nerves_system_fp3.exs`: `config :emerge, compiled_backends: [drm: [:opengl]]`.
  - `priv/samples/13_emerge_and_solve.livemd`: new notebook (Solve counter
    controller + Emerge view with +/− buttons on DRM).
  - `README.md`, `priv/samples/00_introduction.livemd`: notebook 13 added to
    the tables.
  - `scripts/flash-fp3.sh`: **pre-existing unrelated edit by the user**. Leave it alone.

## Why it should work (verified)

- System `mlainez/nerves_system_fp3` v0.2.1 has `CONFIG_DRM_MSM=y` (MDP5/DPU,
  DSI 14nm, HX83112B panel) plus Mesa3D freedreno with GLES, EGL and GBM, and libdrm.
- Emerge fetched the precompiled NIF
  `libemerge_skia-v0.4.0-nif-2.15-aarch64-unknown-linux-gnu--drm.so`, so no
  Rust build is needed for Emerge.
- Every `NEEDED` library of that NIF (libgbm, libfontconfig, libfreetype,
  libstdc++, …) exists in the system staging dir. EGL/GLES are loaded at runtime.
- Emerge's DRM input (`native/emerge_skia/src/drm_input.rs`) handles
  `ABS_MT_*` + `BTN_TOUCH` as direct touch.
- The notebook's modules (`Demo.Counter`, `Demo.State`, `Demo.View`) compile
  against the built emerge/solve beams without warnings.
- Firmware: 170 MB `.fw`, rootfs 147 MiB (limit 250 MiB).

## On-device results (2026-09-29)

- The counter (notebook 13) and the GPU showcase both run. The display is
  `/dev/dri/card0` (connector `DSI-1`); it is the only DRM card.
- Showcase: 59.8 fps at 60 Hz, ~4.8 ms average render per frame, no dropped
  frames, with 8 orbs.
- **Known problem:** after `GenServer.stop` on a viewport, starting another one
  fails with `renderer start failed: "failed to receive DRM backend startup info"`,
  and every later viewport fails the same way. `beam.smp` keeps
  `/dev/dri/card0` fds open. Only a reboot recovers. Still to investigate:
  whether waiting after stop helps, whether it's the DRM master not being
  dropped, and whether to report it upstream to emerge-elixir/emerge.
- On-device runs from the Mac use `ssh nerves.local '<elixir>'`. The phone has
  no SFTP subsystem, so code is sent base64-encoded and run with
  `Code.eval_string`. Unlink the viewport (`Process.unlink/1`) so it outlives
  the SSH session.

## Open questions to check on the device

1. **Which DRM card is the msm one.** `CONFIG_DRM_SIMPLEDRM=y` may take
   `card0` at boot, so msm could be `card1` (the upstream rpi demo hardcodes
   `card1`). The notebook finds the card whose `device/driver` contains "msm".
   Confirm with `ls -l /sys/class/drm/card?/device/driver`.
2. **Whether Mesa freedreno initialises the Adreno 506 (a5xx).** Needs GPU
   firmware (`a506_zap`, `a530_pm4`/`a530_pfp`) in `/lib/firmware`. If GL fails,
   fall back to CPU rendering with `rendering_api: :raster` in `mount/1` opts.
3. **Console handoff.** The notebook unbinds fbcon, as notebook 11 does. The
   `fb0/blank` write is dropped because DRM does its own modeset. Check that the
   console doesn't redraw over the UI.
4. **Touch coordinates and orientation** match the 1080×2160 portrait panel.
5. Emerge and Scenic must not run at the same time. Stop the notebook 11
   viewport first.

## Build environment gotchas (independent of this change)

- **No spaces in the path.** A space in the path breaks the `nerves` dep's
  Makefile (`port.o: No such file or directory`). The repo was renamed from
  `Nerves phone/` to `Nerves-Phone/` for this, so it now builds in place.
- **Elixir from `.tool-versions`** (1.20.4-otp-29) lacked `nerves_bootstrap`.
  It is now installed (1.17.2).
- **Rust:** Homebrew `rustc`/`cargo` in `/opt/homebrew/bin` shadow rustup and
  have no cross targets, so `arm_ai` fails with `can't find crate for core`.
  Added `aarch64-unknown-linux-gnu` via rustup; build with
  `PATH=$HOME/.cargo/bin:$PATH`.
- Build command used:
  ```sh
  PATH=$HOME/.cargo/bin:$PATH MIX_TARGET=nerves_system_fp3 \
    EMERGE_SKIA_HOST_PYTHON=$(which python3) mix firmware
  ```
  `MIX_TARGET=nerves_system_fp3 mix deps.get` must succeed first, because it
  downloads the prebuilt system artifact.

## API notes (Emerge 0.4 / Solve 0.3)

- The upstream `emerge-elixir/nerves_emerge_demo` targets Emerge 0.1 / Solve
  0.1 and is outdated. For example, `Background.gradient(a, b, angle)` is now
  `Background.color(gradient([a, b], angle))`.
- Solve event handlers may have arity 1–5; the notebook uses `(payload, state)`.
- The view uses `use Emerge` + `use Solve.Lookup`, reads with
  `solve(App, :name)`, gets button events from `event(controller, :event)`, and
  rerenders in `handle_solve_updated/2`.
- Views defined in a notebook belong to no OTP app, so `mount/1` must pass
  `otp_app: :nerves_livebook_fp3`, or it raises "could not infer otp_app".
  The phone's `/data` copy of a notebook is never overwritten, so fix it there
  by hand too.
- Viewport options for DRM: `backend: :drm`, `drm_card:`, optionally
  `drm_output:`/`drm_mode:` (list them with `EmergeSkia.drm_outputs/1`).
- Docs: https://hexdocs.pm/emerge, https://hexdocs.pm/solve

## Suggested next steps

1. Flash or upload the firmware and run notebook 13 on the phone.
2. Fix whichever of the open questions above fail.
3. Commit (no conventional-commit prefixes; see recent `git log` for style).
4. Optionally start an Emerge viewport from `application.ex` for a boot-time GUI.
5. Delete this file once it has been acted on.
