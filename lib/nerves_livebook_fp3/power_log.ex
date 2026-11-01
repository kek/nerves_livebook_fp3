defmodule NervesLivebookFP3.PowerLog do
  @moduledoc """
  Logs the battery current every few seconds to a CSV file on `/data`, so
  the power draw of each state (screen on, blanked, suspended) can be
  measured with the phone unplugged and read back afterwards.

      NervesLivebookFP3.PowerLog.start()      # starts a new log
      NervesLivebookFP3.PowerLog.stop()
      NervesLivebookFP3.PowerLog.summary()    # current per state

  Each row records the screen state, read from the backlight: `on`, or
  `blank` when the brightness is 0. The fuel gauge only reports current
  while the phone is awake, so a suspend shows up as a gap between rows.
  The logger notices the gap, because the suspended time counts in
  `/proc/uptime` but not in the monotonic clock, and writes a `suspended`
  row with its length and the voltage before and after it.

  `current_now` is in µA and its sign depends on the driver, so it is
  stored as reported. The phone has no charge counter, and its
  percentage is derived from voltage and jumps under load, so current is
  the only reliable figure.
  """

  use GenServer

  @battery "/sys/class/power_supply/qg-battery"
  @file_path "/data/power_log.csv"
  @header "time_s,uptime_s,state,status,current_now_ua,current_avg_ua,voltage_uv,capacity,cpus_online,suspended_s\n"
  # Samples this soon after a state change are skipped by summary/0, while
  # the current settles.
  @settle_s 15

  def start(interval_s \\ 5) do
    GenServer.start(__MODULE__, interval_s, name: __MODULE__)
  end

  def stop, do: GenServer.stop(__MODULE__)

  def path, do: @file_path

  @impl GenServer
  def init(interval_s) do
    File.write!(@file_path, @header)
    send(self(), :sample)
    {:ok, %{interval_ms: interval_s * 1000, last: nil}}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    now = sample()

    if state.last do
      # Time asleep: boottime advanced but the monotonic clock didn't.
      suspended = now.uptime - state.last.uptime - (now.mono - state.last.mono)

      if suspended > 2 do
        row(%{state.last | state: "suspended", time: state.last.time + 0.001}, suspended)
      end
    end

    row(now, 0)
    Process.send_after(self(), :sample, state.interval_ms)
    {:noreply, %{state | last: now}}
  end

  defp sample do
    %{
      time: :os.system_time(:millisecond) / 1000,
      uptime: uptime(),
      mono: :os.perf_counter(:millisecond) / 1000,
      state: screen_state(),
      status: read(@battery <> "/status"),
      current_now: read(@battery <> "/current_now"),
      current_avg: read(@battery <> "/current_avg"),
      voltage: read(@battery <> "/voltage_now"),
      capacity: read(@battery <> "/capacity"),
      cpus: read("/sys/devices/system/cpu/online")
    }
  end

  defp row(s, suspended) do
    line =
      Enum.join(
        [
          Float.round(s.time, 3),
          Float.round(s.uptime, 2),
          s.state,
          s.status,
          s.current_now,
          s.current_avg,
          s.voltage,
          s.capacity,
          # "0-7" has a dash but no comma, so it needs no quoting.
          s.cpus,
          Float.round(suspended * 1.0, 1)
        ],
        ","
      )

    File.write!(@file_path, line <> "\n", [:append])
  end

  defp screen_state do
    case Path.wildcard("/sys/class/backlight/*") do
      [bl | _] -> if read(bl <> "/brightness") == "0", do: "blank", else: "on"
      [] -> "unknown"
    end
  end

  defp uptime do
    "/proc/uptime" |> File.read!() |> String.split() |> hd() |> String.to_float()
  end

  defp read(path) do
    case File.read(path) do
      {:ok, v} -> String.trim(v)
      {:error, _} -> ""
    end
  end

  @doc """
  Prints the mean current per state and charging status, skipping
  samples within #{@settle_s} s of a state change. Suspends are listed
  one by one, with their length and voltage drop.
  """
  def summary(path \\ @file_path) do
    rows =
      path
      |> File.stream!()
      |> Stream.drop(1)
      |> Enum.map(fn line -> line |> String.trim() |> String.split(",") end)
      |> Enum.map(fn [t, up, st, status, now, avg, v, cap, cpus, susp] ->
        %{
          time: String.to_float(t),
          uptime: String.to_float(up),
          state: st,
          status: status,
          current_now: to_int(now),
          current_avg: to_int(avg),
          voltage: to_int(v),
          capacity: cap,
          cpus: cpus,
          suspended: String.to_float(susp)
        }
      end)

    {suspends, awake} = Enum.split_with(rows, &(&1.state == "suspended"))

    settled =
      awake
      |> Enum.chunk_by(&{&1.state, &1.status})
      |> Enum.flat_map(fn [first | _] = run ->
        Enum.filter(run, &(&1.uptime - first.uptime >= @settle_s))
      end)

    IO.puts("state    status        samples   mean current_now   mean current_avg   (mA)")

    settled
    |> Enum.group_by(&{&1.state, &1.status})
    |> Enum.sort()
    |> Enum.each(fn {{st, status}, rs} ->
      IO.puts(
        :io_lib.format("~-8s ~-13s ~7B   ~16.1f   ~16.1f", [
          st,
          status,
          length(rs),
          mean_ma(rs, :current_now),
          mean_ma(rs, :current_avg)
        ])
      )
    end)

    for s <- suspends do
      after_row = Enum.find(awake, &(&1.uptime > s.uptime))

      drop =
        if after_row && s.voltage && after_row.voltage,
          do: "#{div(s.voltage - after_row.voltage, 1000)} mV voltage drop",
          else: "no voltage after"

      IO.puts("suspended #{round(s.suspended)} s, #{s.status} before, #{drop}")
    end

    :ok
  end

  defp to_int(""), do: nil
  defp to_int(s), do: String.to_integer(s)

  defp mean_ma(rows, key) do
    vals = rows |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)
    if vals == [], do: 0.0, else: Enum.sum(vals) / length(vals) / 1000
  end
end
