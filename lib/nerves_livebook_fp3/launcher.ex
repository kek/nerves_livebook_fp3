defmodule NervesLivebookFP3.Launcher do
  @moduledoc """
  A status screen drawn with Emerge: hostname, time, battery and IP
  addresses, with buttons to dim the screen and to suspend the phone.

      NervesLivebookFP3.Launcher.start()
      NervesLivebookFP3.Launcher.stop()

  Only one UI can own the display, so stop Scenic and Emerge viewports
  from other notebooks first. Once a viewport has been stopped, Emerge
  can't start another one until the phone reboots (see `HANDOFF.md`).
  """

  use Emerge

  @battery "/sys/class/power_supply/qg-battery"

  @doc """
  Detaches the console from the screen and starts the launcher on the
  `msm` display.
  """
  def start do
    bind_console("0")
    start_link(drm_card: drm_card(), name: __MODULE__)
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

  # The card number depends on probe order.
  defp drm_card do
    "/sys/class/drm/card?"
    |> Path.wildcard()
    |> Enum.find(fn card ->
      card |> Path.join("device/driver") |> File.read_link!() |> Path.basename() =~ "msm"
    end)
    |> then(&("/dev/dri/" <> Path.basename(&1)))
  end

  defp backlight, do: "/sys/class/backlight/*" |> Path.wildcard() |> List.first()

  @impl Viewport
  def mount(opts) do
    # mount runs inside the viewport process, so the timer messages come here.
    :timer.send_interval(2_000, :refresh)

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
        brightness: read(backlight() <> "/brightness")
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
    do: {:noreply, Viewport.rerender(Map.merge(%{state | waking: false}, status()))}

  def handle_input(_event, state), do: {:noreply, state}

  @impl Viewport
  def handle_info(:refresh, %{asleep: true} = state), do: {:noreply, state}
  def handle_info(:refresh, %{waking: waking} = state) when waking != false, do: {:noreply, state}
  def handle_info(:refresh, state), do: {:noreply, Viewport.rerender(Map.merge(state, status()))}

  # Brightness 0 also turns off touch, so dim to the lowest level instead
  # and keep the screen tappable.
  def handle_info(:sleep, state) do
    File.write!(backlight() <> "/brightness", "1")
    {:noreply, Viewport.rerender(%{state | asleep: true})}
  end

  def handle_info(:wake, state) do
    File.write!(backlight() <> "/brightness", state.brightness)
    {:noreply, Viewport.rerender(Map.merge(%{state | asleep: false}, status()))}
  end

  # The power button suspends only from the status screen. The press that
  # wakes the phone also arrives here after resume; waking is true then, so
  # it is ignored.
  def handle_info({:input_event, _path, events}, %{asleep: false, waking: false} = state) do
    if {:ev_key, :key_power, 1} in events,
      do: handle_info(:suspend, state),
      else: {:noreply, state}
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
