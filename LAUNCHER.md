# Launcher

`NervesLivebookFP3.Launcher` (`lib/nerves_livebook_fp3/launcher.ex`) is a
status screen drawn with Emerge. It shows the hostname, the time (UTC), the
battery level with its charging state and current, and the IPv4 address of
each network interface, refreshed every two seconds.

| Control | What it does |
|---|---|
| **Screen off** | Dims the backlight to its lowest level and blacks out the screen. Tap anywhere to wake. The backlight isn't turned off fully, because that also turns off touch. |
| **Suspend**, or a short press on the power button | Shows a "Sleeping / waking" screen, then suspends the phone (`s2idle`). Wake it with the power button. Touch takes a few seconds to come back, so the screen stays until a tap gets through. |

```elixir
NervesLivebookFP3.Launcher.start()   # detaches the console, starts on the msm display
NervesLivebookFP3.Launcher.stop()    # stops it, gives the screen back to the console
```

## Starting it at boot

`notebooks/launcher.livemd` calls `start/0`. It isn't in `priv/samples`, so
it doesn't ship to workshop phones. Copy it to a phone with:

```sh
scripts/push-launcher.sh          # to /data/livebook/notebooks, to run by hand
scripts/push-launcher.sh --app    # to /data/livebook/apps, starts at boot
```

Livebook deploys every notebook in `/data/livebook/apps` when it starts,
and a single-session app evaluates all its cells, so reboot after `--app`.
The notebook is the same file either way. Because the app evaluates every
cell, the stop call is a non-runnable snippet (`force_markdown`) rather
than a cell. To remove the app, stop it on Livebook's Apps page and delete
`/data/livebook/apps/launcher.livemd`.

The phone has no SFTP, so both scripts send files over SSH as base64. Close
the notebook in Livebook before pushing, or its autosave overwrites the
copy. Set `NERVES_HOST` to reach a phone other than `nerves.local`.

## Changing the code

Edit `lib/nerves_livebook_fp3/launcher.ex`, then load it into the running
phone without a firmware update:

```sh
scripts/hot-load.sh lib/nerves_livebook_fp3/launcher.ex
```

The file is compiled on the phone and replaces the loaded module. A running
launcher uses the new `render/1` and `handle_info/2` at its next refresh.
`mount/1` doesn't run again and the old state is kept, so changes to
startup or to the state's shape need a reboot. Hot-loaded code is in memory
only: a reboot goes back to the firmware's code. When a change works, ship
it with `mix firmware && mix upload`.

## Known problems

- Only one UI can own the display. Don't run notebooks 11 or 13 while the
  launcher is up.
- After a viewport stops, Emerge can't start another until the phone
  reboots (see `HANDOFF.md`). That includes restarting the launcher.
- A suspend longer than about 30 seconds can reboot the phone. The likely
  cause is `heart` (`HEART_BEAT_TIMEOUT 30` in `rel/vm.args.eex`) counting
  the suspended time as a hung VM. Not confirmed yet.
- After resume, the kernel logs errors from the camera drivers (`ak7375`,
  `s5k4h7yx`). They don't affect the launcher.
- On a Mac's USB port the phone may charge slowly or not at all: in USB
  device mode the charger probably stays at about 500 mA, which the screen
  and radios can use up. Not measured yet. The charging current on the
  launcher shows which way it goes.
