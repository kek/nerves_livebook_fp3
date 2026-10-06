defmodule NervesLivebookFP3.MixProject do
  use Mix.Project

  @app :nerves_livebook_fp3
  @version "0.1.1"

  # Deterministic builds — same input, same firmware bytes.
  System.put_env("ERL_COMPILER_OPTIONS", "deterministic")

  # Scenic renders with Cairo straight to the framebuffer on the phone.
  if Mix.target() != :host, do: System.put_env("SCENIC_LOCAL_TARGET", "cairo-fb")

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.14"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  def application do
    [
      mod: {NervesLivebookFP3.Application, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :inets,
        # Nerves runtime stack
        :nerves_pack,
        # FP3-specific userspace daemons
        :ex_rmtfs,
        :ex_remoteproc,
        :ex_qcom_smgr,
        :ex_qbootctl,
        :ex_audio,
        :fp3_camera,
        :vintage_net_qmi,
        :fp3_modem,
        :ex_nfc,
        :ex_location,
        # The AI stack: this pulls arm_ai, nx_arm, infer_*, nerves_model_hub,
        # cpu_governor, nerves_data_resize via nerves_ai's mix.exs.
        :nerves_ai
      ]
    ]
  end

  defp deps do
    [
      # ---------------- Nerves runtime ----------------
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},
      {:nerves_uevent, "~> 0.1.7", override: true},
      {:nerves_runtime, "~> 0.13.12"},
      {:nerves_pack, "~> 0.7"},
      {:nerves_time, "~> 0.4"},
      {:vintage_net, "~> 0.13"},
      {:vintage_net_ethernet, "~> 0.11"},

      # ---------------- Livebook ----------------
      {:livebook, "~> 0.19"},

      # Livebook 0.19.10 pins exact versions with security advisories.
      # Override to the fixed releases until Livebook ships them.
      {:bandit, "~> 1.12.5", override: true},
      {:phoenix, "~> 1.8.9", override: true},
      {:phoenix_live_view, "~> 1.1.33", override: true},
      {:plug, "~> 1.19.5", override: true},
      {:protobuf, "~> 0.16.1", override: true},
      {:req, "~> 0.6.1", override: true},

      # ---------------- Kino (used by the notebooks) ----------------
      {:kino, "~> 0.14"},

      # Touchscreen and buttons (Linux input events)
      {:input_event, "~> 1.4"},

      # Scenic UI on the screen. Pinned to the commits that compile on
      # Elixir 1.19+, which aren't released on Hex yet.
      {:scenic, github: "ScenicFramework/scenic", ref: "e0ae569", override: true},
      {:scenic_driver_local,
       github: "ScenicFramework/scenic_driver_local", ref: "9988a05", targets: :nerves_system_fp3},

      # Emerge UI on the screen (DRM + OpenGL ES through Mesa freedreno),
      # with Solve for state. The native renderer is a precompiled NIF.
      {:emerge, "~> 0.4.0"},
      {:solve, "~> 0.3.0"},

      # ---------------- AI stack ----------------
      # nerves_ai pulls arm_ai (whose NIF builds from source with Rust),
      # nx_arm, the infer_* libraries and the boot helpers.
      {:nerves_ai, github: "mlainez/nerves_ai", override: true},

      # ---------------- FP3 hardware userspace ----------------
      {:ex_rmtfs, github: "mlainez/ex_rmtfs"},
      {:ex_remoteproc, github: "mlainez/ex_remoteproc", override: true},
      {:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr", override: true},
      {:ex_qbootctl, github: "mlainez/ex_qbootctl", override: true},
      {:ex_audio, github: "mlainez/ex_audio", override: true},
      {:fp3_camera, github: "mlainez/fp3_camera", override: true},
      {:qmi, github: "mlainez/qmi", branch: "qrtr-transport", override: true},
      # Forks with boot-race and power-off fixes, until
      # mlainez/vintage_net_qmi#1 and mlainez/fp3_modem#1 are merged.
      {:vintage_net_qmi, github: "kek/vintage_net_qmi", branch: "fix-boot-races", override: true},
      {:fp3_modem, github: "kek/fp3_modem", branch: "low-power-off", override: true},
      {:ex_nfc, github: "mlainez/ex_nfc", override: true},
      {:ex_location, github: "mlainez/ex_location", override: true},
      {:blue_heron, github: "mlainez/blue_heron", targets: :nerves_system_fp3},

      # ---------------- The nerves_system_fp3 ----------------
      # The prebuilt system comes from the tag's GitHub release.
      {:nerves_system_fp3,
       github: "mlainez/nerves_system_fp3",
       tag: "v0.2.2",
       runtime: false,
       targets: :nerves_system_fp3}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      # Livebook runs doctests with ExUnit and shows docs in the editor.
      applications: [ex_unit: :load],
      strip_beams: [keep: ["Docs"]]
    ]
  end
end
