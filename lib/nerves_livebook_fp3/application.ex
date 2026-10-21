defmodule NervesLivebookFP3.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Livebook needs writable notebooks, but the release is read-only:
    # sync the shipped notebooks to /data, leaving attendee edits alone,
    # and star them so they're listed on Livebook's home page.
    sync_notebooks() |> star_notebooks()

    # Scenic's supervisor, so notebooks can start viewports on the screen.
    # The task starts the launcher once the display is up, unless
    # NervesLivebookFP3.Launcher.autostart(false) was run on this phone.
    children = [
      {Scenic, []},
      {Task, fn -> NervesLivebookFP3.Launcher.start_at_boot(NervesLivebookFP3.Supervisor) end}
      | microphone_warm_up()
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children,
             strategy: :one_for_one,
             name: NervesLivebookFP3.Supervisor
           ) do
      validate_firmware()
      {:ok, pid}
    end
  end

  # The first capture after boot records silence on both models; later ones
  # are fine. A throwaway capture as soon as the card exists means the first
  # recording anyone makes already works.
  @microphone_route [
    {"MultiMedia2 Mixer SLIMBUS_0_TX", :on},
    {"SLIM TX7 MUX", "DEC7"},
    {"ADC MUX7", "DMIC"},
    {"DMIC MUX7", "DMIC1"},
    {"AIF1_CAP Mixer SLIM TX7", :on}
  ]

  defp microphone_warm_up do
    if Nerves.Runtime.mix_target() == :host,
      do: [],
      else: [Supervisor.child_spec({Task, &warm_up_microphone/0}, id: :microphone_warm_up)]
  end

  defp warm_up_microphone do
    if wait_for_card(120) do
      Enum.each(@microphone_route, fn {name, value} -> ExAudio.cset(name, value) end)

      case System.cmd("arecord", ~w(-q -D hw:0,1 -f S16_LE -r 48000 -c 1 -d 1 /dev/null),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> Logger.warning("[workshop] microphone warm-up failed: #{String.trim(out)}")
      end
    else
      Logger.warning("[workshop] no sound card, microphone not warmed up")
    end
  end

  # The card appears once the ADSP is up; its controls a moment later.
  defp wait_for_card(0), do: false

  defp wait_for_card(tries) do
    if File.exists?("/proc/asound/card0") do
      Process.sleep(1_000)
      true
    else
      Process.sleep(500)
      wait_for_card(tries - 1)
    end
  end

  # fwup installs a firmware as not validated; this release has started,
  # so mark its slot valid.
  defp validate_firmware do
    if Nerves.Runtime.mix_target() != :host do
      case Nerves.Runtime.validate_firmware() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[workshop] firmware validation failed: #{inspect(reason)}")
      end
    end
  end

  defp notebooks_dest do
    Application.get_env(:nerves_livebook_fp3, :notebooks_dest, "/data/livebook/notebooks")
  end

  # Keeps /data in step with the shipped notebooks. A manifest records the
  # checksum of each notebook as last shipped, so a copy nobody edited is
  # updated or removed with the firmware, while edited copies are kept.
  defp sync_notebooks do
    source = Application.app_dir(:nerves_livebook_fp3, "priv/samples")
    dest = notebooks_dest()
    manifest_path = Path.join(dest, ".shipped.json")
    File.mkdir_p!(dest)

    old_manifest =
      case File.read(manifest_path) do
        {:ok, json} -> JSON.decode!(json)
        {:error, _} -> %{}
      end

    shipped = source |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".livemd"))

    new_manifest =
      Map.new(shipped, fn name ->
        content = source |> Path.join(name) |> File.read!() |> livebook_format()
        dst = Path.join(dest, name)
        sha = sha256_of(content)

        cond do
          not File.exists?(dst) -> File.write!(dst, content)
          unedited?(dst, old_manifest[name]) and sha256(dst) != sha -> File.write!(dst, content)
          true -> :ok
        end

        {name, sha}
      end)

    removed =
      for {name, sha} <- old_manifest, not Map.has_key?(new_manifest, name) do
        dst = Path.join(dest, name)
        if unedited?(dst, sha), do: File.rm(dst)
        dst
      end

    File.write!(manifest_path, JSON.encode!(new_manifest))
    {shipped, removed}
  rescue
    e ->
      Logger.warning("[workshop] notebook sync failed: #{Exception.message(e)}")
      {[], []}
  end

  defp unedited?(path, shipped_sha), do: shipped_sha != nil and sha256(path) == shipped_sha

  defp sha256(path), do: path |> File.read!() |> sha256_of()

  defp sha256_of(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # Livebook rewrites a notebook in its own format when it saves it.
  # Shipping that format means a notebook opened and saved without
  # changes still counts as unedited and keeps receiving updates.
  defp livebook_format(markdown) do
    {notebook, _warnings} = Livebook.LiveMarkdown.notebook_from_livemd(markdown)
    {source, _warnings} = Livebook.LiveMarkdown.notebook_to_livemd(notebook)
    source
  end

  # Starred notebooks show newest first, and re-starring keeps an entry
  # where it is, so unstar the shipped ones and star them again in reverse
  # order: 00 comes out on top.
  defp star_notebooks({shipped, removed}) do
    if Process.whereis(Livebook.NotebookManager) do
      dest = notebooks_dest()

      gone =
        for %{file: file} <- Livebook.NotebookManager.starred_notebooks(),
            String.starts_with?(file.path, dest),
            not File.exists?(file.path),
            do: file.path

      shipped_paths = Enum.map(shipped, &Path.join(dest, &1))

      for path <- Enum.uniq(removed ++ gone ++ shipped_paths) do
        Livebook.NotebookManager.remove_starred_notebook(Livebook.FileSystem.File.local(path))
      end

      for name <- Enum.sort(shipped, :desc),
          path = Path.join(dest, name),
          File.exists?(path) do
        file = Livebook.FileSystem.File.local(path)
        Livebook.NotebookManager.add_starred_notebook(file, notebook_title(path, name))
      end
    end
  rescue
    e -> Logger.warning("[workshop] starring notebooks failed: #{Exception.message(e)}")
  end

  defp notebook_title(path, fallback) do
    path
    |> File.stream!()
    |> Enum.find_value(fallback, fn
      "# " <> title -> String.trim(title)
      _ -> nil
    end)
  end
end
