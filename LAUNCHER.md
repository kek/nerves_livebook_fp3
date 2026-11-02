# Launcher

`NervesLivebookFP3.Launcher` (`lib/nerves_livebook_fp3/launcher.ex`) is a
status screen drawn with Emerge. It shows the hostname, the time (UTC), the
battery level with its charging state and current, and the IPv4 address of
each network interface, refreshed every two seconds.

| Control | What it does |
|---|---|
| **Screen off**, or a press on the power button | Cuts the backlight and powers down the panel and display pipeline — the lowest-power state short of suspend. Networking keeps running. A press on the power button wakes it in about 150 ms, and touch works straight away. The panel being off also kills touch, so a tap is a fallback wake, not the main one. |
| **Suspend** | Shows a "Sleeping / waking" screen, then suspends the phone (`s2idle`). Wake it with the power button. Touch takes a few seconds to come back, so the screen stays until a tap gets through. Only reachable from this button — never on its own, and the power button no longer triggers it. |

The screen also blanks on its own after a period with no touch:
`screen_blank_timeout` (default 2 minutes) in `config.exs`. Set it to
`nil` to turn that off. The phone never suspends on its own.

```elixir
config :nerves_livebook_fp3, screen_blank_timeout: :timer.minutes(2)
```

```elixir
NervesLivebookFP3.Launcher.start()   # detaches the console, starts on the msm display
NervesLivebookFP3.Launcher.stop()    # stops it, gives the screen back to the console
```

The launcher sets the backlight to `screen_brightness` (default 512, out of
4095) when it starts. Brightness looks much the same from 4095 down to about
1024, but the current doesn't: on battery with this screen showing, 4095 draws
about 545 mA, 1024 about 339 mA, 512 about 304 mA and 256 less still.

```elixir
config :nerves_livebook_fp3, screen_brightness: 512
```

## Starting it at boot

The firmware starts the launcher at boot unless autostart has been turned
off for this phone. A task in `NervesLivebookFP3.Application` waits up to
30 seconds for the display driver, then starts the launcher as a
temporary child of `NervesLivebookFP3.Supervisor`, so a crash doesn't
restart it in a loop.

```elixir
NervesLivebookFP3.Launcher.autostart(false)   # don't start at boot on this phone
NervesLivebookFP3.Launcher.autostart(true)    # back to the default
NervesLivebookFP3.Launcher.autostart?()
```

The setting is the file `/data/launcher/autostart`. It survives firmware
updates and is on by default, so a freshly flashed phone starts the
launcher without calling `autostart(true)` first.

Don't run the launcher as a Livebook app. While a Livebook runtime is
active, Livebook registers its own process as `:standard_error`. On this
OTP version, the console driver `user_drv` calls `io:setopts(standard_error,
...)` while handling an encoding change on `user`, and Livebook's process
forwards that back to `user`, which is waiting on `user_drv`. The two
deadlock, and from then on every SSH shell crashes when you press Enter.
An app keeps a runtime active from boot, so the deadlock is only one
encoding change away.

`notebooks/launcher.livemd` has cells for autostart, starting and stopping.
It isn't in `priv/samples`, so it doesn't ship to workshop phones. Copy it
to a phone with `scripts/push-launcher.sh`. The phone has no SFTP, so it
goes over SSH as base64. Close the notebook in Livebook before pushing, or
its autosave overwrites the copy. Set `NERVES_HOST` to reach a phone other
than `nerves.local`.

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
- The SSH shell deadlock above can also happen while a notebook session is
  open, since Livebook swaps `:standard_error` then too. `ssh -T` (no
  line editing) and `ssh nerves.local '<elixir>'` keep working; a reboot
  clears it.
- An earlier version of this list said a suspend longer than about 30
  seconds could reboot the phone, and blamed `heart`. That doesn't happen
  on the current firmware. Suspends of 75 seconds and 5 minutes on USB
  power, and about an hour on battery (started from the Suspend button,
  woken with the power button), all resumed without a reboot. `heart`
  couldn't have caused it anyway: nerves_heart and the kernel's software
  watchdog both time against `CLOCK_MONOTONIC`, which stops while the
  phone is suspended, so time asleep never counts toward their timeouts.
- Each time the display powers down, the kernel logs a `vblank timeout` and
  `wait for commit done returned -110` from `msm_dpu`. The display comes back
  normally afterwards, so this looks harmless, but the cause hasn't been
  looked into.
- After resume, the kernel logs errors from the camera drivers (`ak7375`,
  `s5k4h7yx`). They don't affect the launcher.
- On a Mac's USB port the phone may charge slowly or not at all: in USB
  device mode the charger probably stays at about 500 mA, which the screen
  and radios can use up. Not measured yet. The charging current on the
  launcher shows which way it goes.
