defmodule NervesLivebookFP3.Launcher do
  @moduledoc """
  A status screen drawn with Emerge: hostname, time, battery and IP
  addresses, with buttons to dim the screen and to suspend the phone.

      NervesLivebookFP3.Launcher.start()
      NervesLivebookFP3.Launcher.stop()

  Starts at boot by default. The setting is a file on `/data`, so it
  survives firmware updates; run `autostart(false)` to opt a phone out.

  The power button blanks the screen and wakes it again; blanked, it cuts
  the backlight entirely to use as little power as possible, and wakes
  instantly on the next press. The screen also blanks on its own after a
  period of inactivity; see `screen_blank_timeout` in `config.exs`. Suspend
  is manual only, from the "Suspend" button on the status screen.

  Only one UI can own the display, so stop Scenic and Emerge viewports
  from other notebooks first. Once a viewport has been stopped, Emerge
  can't start another one until the phone reboots (see `HANDOFF.md`).
  """

  use Emerge

  @battery "/sys/class/power_supply/qg-battery"
  @autostart "/data/launcher/autostart"

  @doc """
  Detaches the console from the screen and starts the launcher on the
  `msm` display.
  """
  def start do
    bind_console("0")
    start_link(drm_card: drm_card(), name: __MODULE__)
  end

  @doc """
  Turns starting the launcher at boot on or off for this phone. On by
  default, so a freshly flashed phone starts the launcher without having
  to call this first; call `autostart(false)` to opt a phone out.
  """
  def autostart(enabled) when is_boolean(enabled) do
    File.mkdir_p!(Path.dirname(@autostart))
    File.write!(@autostart, to_string(enabled))
  end

  def autostart? do
    case File.read(@autostart) do
      {:ok, value} -> value == "true"
      {:error, _} -> true
    end
  end

  @doc """
  Starts the launcher under `supervisor` if autostart is on. The display
  driver may still be probing at boot, so it waits up to 30 seconds for it.
  """
  def start_at_boot(supervisor) do
    if autostart?() and wait_for_display(30) do
      spec = %{id: __MODULE__, start: {__MODULE__, :start, []}, restart: :temporary}
      Supervisor.start_child(supervisor, spec)
    end
  end

  defp wait_for_display(0), do: false

  defp wait_for_display(tries) do
    find_drm_card() != nil or (Process.sleep(1_000) && wait_for_display(tries - 1))
  end

  @doc "Stops the launcher and gives the screen back to the console."
  def stop do
    GenServer.stop(__MODULE__)
    bind_console("1")
  end

  # The IEx console is drawn on the screen too, through fbcon.
  defp bind_console(value) do
    "/sys/class/vtconsole/vtcon*"
    |> Path.wildcard()
    |> Enum.find(&(File.read!(Path.join(&1, "name")) =~ "frame buffer"))
    |> Path.join("bind")
    |> File.write!(value)
  end

  defp drm_card, do: "/dev/dri/" <> Path.basename(find_drm_card())

  # The card number depends on probe order.
  defp find_drm_card do
    "/sys/class/drm/card?"
    |> Path.wildcard()
    |> Enum.find(fn card ->
      case File.read_link(Path.join(card, "device/driver")) do
        {:ok, driver} -> Path.basename(driver) =~ "msm"
        {:error, _} -> false
      end
    end)
  end

  defp backlight, do: "/sys/class/backlight/*" |> Path.wildcard() |> List.first()

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Idle timeouts in ms, or nil to disable. Configurable per build in
  # config.exs; see LAUNCHER.md.
  defp screen_blank_timeout,
    do: Application.get_env(:nerves_livebook_fp3, :screen_blank_timeout, :timer.minutes(2))

  @impl Viewport
  def mount(opts) do
    # mount runs inside the viewport process, so the timer messages come here.
    :timer.send_interval(2_000, :refresh)
    :timer.send_interval(1_000, :check_idle)

    # Key events from the power button come to this process as
    # {:input_event, path, events}.
    with {path, _info} <-
           Enum.find(InputEvent.enumerate(), fn {_path, info} -> info.name =~ ~r/pwrkey/i end) do
      {:ok, _} = InputEvent.start_link(path: path)
    end

    state =
      Map.merge(status(), %{
        asleep: false,
        waking: false,
        brightness: read(backlight() <> "/brightness"),
        last_active: now_ms()
      })

    # Raw touch presses go to handle_input/2, which tells us when touch works
    # again after a resume.
    {:ok, state,
     Keyword.merge(
       [
         backend: :drm,
         otp_app: :nerves_livebook_fp3,
         viewport: [input_mask: EmergeSkia.input_mask_cursor_button()]
       ],
       opts
     )}
  end

  # waking is false, :suspending (sleep screen drawn, suspend not entered
  # yet) or true (resumed, touch not back yet). The touch controller takes a
  # while to come back after a resume; the first press that gets through
  # means it is back.
  @impl Viewport
  def handle_input(_event, %{waking: true} = state),
    do:
      {:noreply,
       Viewport.rerender(Map.merge(%{state | waking: false, last_active: now_ms()}, status()))}

  def handle_input(_event, state), do: {:noreply, %{state | last_active: now_ms()}}

  @impl Viewport
  def handle_info(:refresh, %{asleep: true} = state), do: {:noreply, state}
  def handle_info(:refresh, %{waking: waking} = state) when waking != false, do: {:noreply, state}
  def handle_info(:refresh, state), do: {:noreply, Viewport.rerender(Map.merge(state, status()))}

  # A tick of the idle clock: blanks the screen after screen_blank_timeout
  # with no touch. Suspend never happens on its own.
  def handle_info(:check_idle, %{waking: waking} = state) when waking != false,
    do: {:noreply, state}

  def handle_info(:check_idle, %{asleep: true} = state), do: {:noreply, state}

  def handle_info(:check_idle, state) do
    if timeout_elapsed?(screen_blank_timeout(), now_ms() - state.last_active),
      do: handle_info(:sleep, state),
      else: {:noreply, state}
  end

  # Cuts the backlight entirely rather than dimming, so blanked is the
  # lowest-power state short of suspend. That also kills touch, so waking
  # from here is meant to go through the power button; the full-screen tap
  # target below is left in place in case touch still gets through.
  def handle_info(:sleep, state) do
    File.write!(backlight() <> "/brightness", "0")
    {:noreply, Viewport.rerender(%{state | asleep: true})}
  end

  def handle_info(:wake, state) do
    File.write!(backlight() <> "/brightness", state.brightness)

    {:noreply,
     Viewport.rerender(Map.merge(%{state | asleep: false, last_active: now_ms()}, status()))}
  end

  # The power button toggles the blanked, low-power state: a press blanks
  # the screen from the status screen, and wakes it from blanked. Suspend
  # only happens from the UI button. A press right after a resume also
  # arrives here, with waking still true; that one's ignored, since touch
  # coming back is what ends the waking state.
  def handle_info({:input_event, _path, events}, %{waking: false} = state) do
    cond do
      {:ev_key, :key_power, 1} not in events -> {:noreply, state}
      state.asleep -> handle_info(:wake, state)
      true -> handle_info(:sleep, state)
    end
  end

  def handle_info({:input_event, _path, _events}, state), do: {:noreply, state}

  # Draw the sleep screen first and give the renderer time to show it, so
  # it is what's on the display when the phone resumes.
  def handle_info(:suspend, state) do
    Process.send_after(self(), :enter_suspend, 500)
    {:noreply, Viewport.rerender(%{state | waking: :suspending})}
  end

  # Writing "mem" blocks until the phone resumes, so do it outside the
  # viewport process. Touches from now on mean touch is back.
  def handle_info(:enter_suspend, state) do
    viewport = self()
    spawn(fn -> send(viewport, {:resumed, File.write("/sys/power/state", "mem")}) end)
    {:noreply, %{state | waking: true}}
  end

  def handle_info({:resumed, :ok}, state), do: {:noreply, state}

  def handle_info({:resumed, error}, state) do
    IO.puts("Suspend failed: #{inspect(error)}")
    {:noreply, Viewport.rerender(Map.merge(%{state | waking: false}, status()))}
  end

  defp timeout_elapsed?(nil, _idle_ms), do: false
  defp timeout_elapsed?(timeout_ms, idle_ms), do: idle_ms >= timeout_ms

  defp status do
    {:ok, host} = :inet.gethostname()

    %{
      host: to_string(host),
      time: Time.utc_now() |> Time.truncate(:second) |> Time.to_string(),
      battery: read(@battery <> "/capacity") |> String.to_integer(),
      charging: read(@battery <> "/status"),
      current_ma: current_ma(),
      ips: ip_addresses()
    }
  end

  defp read(path), do: path |> File.read!() |> String.trim()

  # current_now is in µA. The sign convention depends on the driver, so it
  # is shown as reported.
  defp current_ma do
    case File.read(@battery <> "/current_now") do
      {:ok, ua} -> div(ua |> String.trim() |> String.to_integer(), 1000)
      {:error, _} -> nil
    end
  end

  # IPv4 addresses per interface, skipping loopback.
  defp ip_addresses do
    {:ok, ifs} = :inet.getifaddrs()

    for {name, opts} <- ifs,
        name != ~c"lo",
        {:addr, {_, _, _, _} = addr} <- opts,
        do: {to_string(name), addr |> :inet.ntoa() |> to_string()}
  end

  @impl Viewport
  def render(%{asleep: true}) do
    Input.button(
      [width(fill()), height(fill()), Background.color(color(:black)), Event.on_press(:wake)],
      none()
    )
  end

  def render(%{waking: waking}) when waking != false do
    column(
      [
        width(fill()),
        height(fill()),
        spacing(60),
        Background.color(color(:slate, 950)),
        Font.color(color(:slate, 300))
      ],
      [
        el([center_x(), center_y(), Font.size(96)], text("Sleeping / waking")),
        el(
          [center_x(), center_y(), Font.size(56), Font.color(color(:slate, 500))],
          text("Press power to wake, then tap")
        )
      ]
    )
  end

  def render(s) do
    column(
      [
        width(fill()),
        height(fill()),
        padding_xy(80, 160),
        spacing(80),
        Background.color(gradient([color(:slate, 950), color(:indigo, 900)], 180)),
        Font.color(color(:white))
      ],
      [
        row([width(fill())], [
          el([Font.size(64)], text(s.host)),
          el([align_right(), Font.size(64)], text(s.time <> " UTC"))
        ]),
        battery(s.battery, s.charging, s.current_ma),
        column(
          [width(fill()), spacing(30)],
          [el([Font.size(56), Font.color(color(:slate, 400))], text("Network"))] ++
            for {name, ip} <- s.ips do
              row([width(fill())], [
                el([Font.size(64)], text(name)),
                el([align_right(), Font.size(64)], text(ip))
              ])
            end
        ),
        row([center_x(), spacing(40)], [
          action_button("Screen off", :sleep),
          action_button("Suspend", :suspend)
        ])
      ]
    )
  end

  defp battery(percent, charging, current_ma) do
    fill_color =
      cond do
        percent <= 15 -> color(:rose, 500)
        percent <= 40 -> color(:amber, 400)
        true -> color(:emerald, 400)
      end

    column([width(fill()), spacing(30)], [
      row([width(fill())], [
        el([Font.size(56), Font.color(color(:slate, 400))], text("Battery")),
        el(
          [align_right(), Font.size(56), Font.color(color(:slate, 400))],
          text(if current_ma, do: "#{charging} · #{current_ma} mA", else: charging)
        )
      ]),
      el(
        [
          width(fill()),
          height(px(140)),
          Border.rounded(40),
          Background.color(color(:slate, 800))
        ],
        el(
          [
            width(px(round(9.2 * percent))),
            height(fill()),
            Border.rounded(40),
            Background.color(fill_color),
            Font.size(80),
            Font.color(color(:slate, 950))
          ],
          el([center_x(), center_y()], text("#{percent}%"))
        )
      )
    ])
  end

  defp action_button(label, message) do
    Input.button(
      [
        padding_xy(80, 50),
        Border.rounded(60),
        Background.color(color(:slate, 800)),
        Font.size(64),
        Event.on_press(message)
      ],
      el([center_x(), center_y()], text(label))
    )
  end
end
