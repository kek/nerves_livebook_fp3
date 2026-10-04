# nerves_livebook_fp3

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on
> Fairphone 3 hardware. There are no stability guarantees and APIs will
> change without notice.

Workshop firmware for the Fairphone 3 and 3+. It boots straight into a
Livebook with the [`nerves_ai`](https://github.com/mlainez/nerves_ai)
edge-AI stack (LLM, speech to text and object detection) and the
Fairphone 3 hardware libraries loaded.

## At workshop time

1. Power on the phone and connect it to your laptop over USB.
2. Open `http://nerves.local:4000` (or `http://nerves-XXXX.local:4000`
   when several phones share a network).
3. Open a notebook and evaluate it.

## Notebooks

| Notebook | What it covers |
|---|---|
| `00_introduction.livemd` | The phone, what Nerves can use, boot chain, partitions, first-time flashing |
| `01_wifi.livemd` | Connect the phone to Wi-Fi |
| `02_led_flash_vibrator.livemd` | RGB notification LED, flashlight, vibrator |
| `03_sensors.livemd` | Accelerometer, gyroscope, magnetometer, proximity |
| `04_battery.livemd` | Battery level, charging status, voltage, current, temperature |
| `05_cameras.livemd` | Photos from both cameras, tuning the picture and focus, H.264 video stream |
| `06_nfc.livemd` | Detect NFC tags and contactless cards |
| `07_gps.livemd` | Satellites in view and position fixes |
| `08_modem.livemd` | IMEI, operating mode, home network, signal strength |
| `09_bluetooth.livemd` | Scan for BLE devices, advertise the phone, share its battery level over GATT |
| `10_audio.livemd` | Loudspeaker, earpiece and microphone: tones, recording, playback |
| `11_screen_touch_buttons.livemd` | Draw on the screen, touch input, volume and power buttons |
| `12_ai_on_the_phone.livemd` | The AI stack, CPU placement, Nx speed, YOLO object detection, Whisper speech to text, TinyLlama chat, generated sound |

Notebooks ship in `priv/samples` and are copied to
`/data/livebook/notebooks` at boot, then starred so they appear on
Livebook's home page. A notebook that's already on `/data` is never
overwritten, so attendee edits survive reboots and firmware updates.

The hardware notebooks use these libraries, all started at boot:
`ex_qcom_smgr` (sensors), `fp3_camera`, `ex_nfc`, `ex_location` (GPS,
and the QMI client the modem notebook uses), plus the kernel's LED
interface and the system's `rumble` tool for the vibrator, and
`input_event` for the touchscreen and buttons. `ex_audio`
sets up the loudspeaker route and `ex_qbootctl` marks each boot slot
successful.

## Models

Models are too large for the firmware image (the root filesystem is
250 MiB), and nothing downloads them at boot. Each AI notebook fetches
the model it needs with `NervesAI.Models.ensure_one/3` the first time it
runs: the phone downloads it over Wi-Fi into `/data/models`, checks its
SHA-256, and reuses it afterwards. The notebooks include a cell to connect
the phone to Wi-Fi, and start the matching capability (`NervesAI.LLM`,
`NervesAI.STT`, `NervesAI.Vision`) once its model is on disk.

## For the workshop organiser

### Prerequisites

* Erlang/OTP 29.1.1 and Elixir 1.20.4 (see `.tool-versions`), matching
  the official Nerves systems, and the `nerves_bootstrap` archive.
* Rust 1.98 or newer with the `aarch64-unknown-linux-gnu` target
  (`rustup toolchain install 1.99.0 -t aarch64-unknown-linux-gnu`, then
  `RUSTUP_TOOLCHAIN=1.99.0`), and `cmake` and `git`. `whisper_cpp`,
  `llama_cpp_ex` and `cpu_governor` build their native code from source for
  the phone's ARMv8.0 cores: `mix.exs` sets the flags for target builds
  (plain `armv8-a`, no dot-product or fp16 instructions; the precompiled
  `whisper_cpp` artifact needs ARMv8.2 and is never used).
* An SSH public key in `~/.ssh`, which is baked into the firmware for
  `mix upload` and SSH access.

### Build the firmware

```sh
export MIX_TARGET=nerves_system_fp3
mix deps.get
mix firmware
```

The first build downloads the prebuilt `nerves_system_fp3` from its
GitHub release (about 360 MB).

Cellular data is off unless you pass the SIM's APN at build time, for
example `FP3_APN=internet.be mix firmware`. That adds the modem's QMI
interface and `Fp3Modem.PowerManager` to the network config.

For a workshop venue, build with its Wi-Fi so every phone joins it on
first boot: `FP3_WIFI_SSID=venue FP3_WIFI_PASSPHRASE=secret mix firmware`
(leave out the passphrase for an open network). The credentials end up
in the image. People can pick another network with the Wi-Fi notebook.

### Flash a device

`scripts/flash-fp3.sh` flashes a phone over USB. Put the phone in fastboot
mode (power it off, hold Volume Down, plug in USB) and run:

```sh
scripts/flash-fp3.sh --build    # builds nerves_livebook_fp3.img, then flashes it
scripts/flash-fp3.sh            # flashes an image that's already built
scripts/flash-fp3.sh --loop     # one phone after another
```

It checks what the phone has and does only what's needed: unlocks a stock
bootloader by writing an unlocked `devinfo` partition and rebooting into
fastboot (no Android OEM unlocking needed), installs the dummy `dtbo` and
lk2nd 22.0 on `boot`, then writes the image to `userdata`. On a phone that
already runs lk2nd it only rewrites `userdata`. Either way the phone's data
is erased. `--dry-run` shows what it would do. The manual steps are in the
[`nerves_system_fp3` README](https://github.com/mlainez/nerves_system_fp3#flashing).

After that, update over the network:

```sh
mix upload
```

## What's running on the device

```
nerves_livebook_fp3
├── nerves_system_fp3   kernel, bootloader glue, daemons (rmtfs, qbootctl, …)
├── nerves_ai           the AI composer: LLM / STT / Vision facades, model downloads, WAV
│   ├── nerves_ai_fp3   Fairphone 3 profile: fast-cluster pinning, 4 threads, model catalog
│   ├── cpu_governor    topology, performance bursts, thread affinity (Rust NIF)
│   └── nerves_data_resize  first-boot F2FS grow
├── llama_cpp_ex        LLM engine (llama.cpp)
├── whisper_cpp         speech to text engine (whisper.cpp, Silero VAD)
├── evision             vision engine (OpenCV, YOLOv5n), brings nx
├── ex_rmtfs, ex_remoteproc   modem storage daemon, ADSP start-up
├── ex_qcom_smgr, fp3_camera, ex_audio, ex_nfc, ex_location, ex_qbootctl
├── fp3_modem, vintage_net_qmi, qmi   cellular (only with FP3_APN)
└── livebook + kino
```

## Security

Livebook runs with authentication disabled: anyone who can reach port
4000 can run code on the phone. Only connect it to networks you trust.

Livebook 0.19.10, the current release, pins exact versions of its web
stack. `mix hex.audit` reports advisories against several of them
(Bandit, Plug, Phoenix, Req, protobuf), and they can't be overridden
without breaking Livebook's own constraints. Update Livebook when a
release with patched dependencies is available.

## License

Apache-2.0.
