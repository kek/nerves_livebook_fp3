defmodule NervesLivebookFP3.MixProject do
  use Mix.Project

  @app :nerves_livebook_fp3
  @version "0.1.1"

  # Deterministic builds — same input, same firmware bytes.
  System.put_env("ERL_COMPILER_OPTIONS", "deterministic")

  # Scenic renders with Cairo straight to the framebuffer on the phone.
  if Mix.target() != :host, do: System.put_env("SCENIC_LOCAL_TARGET", "cairo-fb")

  # Native AI libraries for the Fairphone 3's ARMv8.0 cores (neither cluster
  # has dotprod or fp16; a native or ARMv8.2 build dies with SIGILL):
  # llama.cpp and whisper.cpp are built from source for plain armv8-a, and
  # the precompiled whisper_cpp artifact (ARMv8.2) is never used.
  if Mix.target() != :host do
    for {key, value} <- [
          {"LLAMA_BACKEND", "cpu"},
          {"LLAMA_CPU_ARM_ARCH", "armv8-a"},
          {"WHISPER_CPP_BUILD", "1"},
          {"GGML_NATIVE", "OFF"},
          {"GGML_CPU_ARM_ARCH", "armv8-a"},
          # Rust NIFs (whisper_cpp, cpu_governor) cross-compile with the Nerves
          # toolchain, which is on PATH while dependencies compile. whisper-rs-sys
          # uses its bundled bindings instead of generating them with libclang.
          {"CARGO_BUILD_TARGET", "aarch64-unknown-linux-gnu"},
          {"CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER", "aarch64-nerves-linux-gnu-gcc"},
          {"WHISPER_DONT_GENERATE_BINDINGS", "1"}
        ] do
      System.put_env(key, value)
    end
  end

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
        # Runs the Fairphone 3 profile at boot: thread pinning and the
        # first-boot data partition grow.
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
      {:plug, "~> 1.16"},

      # ---------------- Kino (used by the notebooks) ----------------
      {:kino, "~> 0.14"},

      # Touchscreen and buttons (Linux input events)
      {:input_event, "~> 1.4"},

      # Scenic UI on the screen. Pinned to the commits that compile on
      # Elixir 1.19+, which aren't released on Hex yet.
      {:scenic, github: "ScenicFramework/scenic", ref: "e0ae569", override: true},
      {:scenic_driver_local,
       github: "ScenicFramework/scenic_driver_local", ref: "9988a05", targets: :nerves_system_fp3},

      # ---------------- AI stack ----------------
      # nerves_ai composes the stack and the Fairphone 3 profile places work
      # on the fast cluster. The capability packages are built for the phone
      # only.
      sibling(:nerves_ai, "NERVES_AI_PATH"),
      sibling(:nerves_ai_fp3, "NERVES_AI_FP3_PATH"),
      sibling(:cpu_governor, "CPU_GOVERNOR_PATH"),
      sibling(:nerves_data_resize, "NERVES_DATA_RESIZE_PATH"),
      {:llama_cpp_ex, "~> 0.8", targets: :nerves_system_fp3},
      {:whisper_cpp, "~> 0.5", targets: :nerves_system_fp3},
      {:evision, "~> 1.0.1-rc.0", targets: :nerves_system_fp3},
      # Builds whisper_cpp from source and cpu_governor's NIF from its crate.
      {:rustler, "~> 0.38.0", runtime: false},

      # ---------------- FP3 hardware userspace ----------------
      {:ex_rmtfs, github: "mlainez/ex_rmtfs"},
      {:ex_remoteproc, github: "mlainez/ex_remoteproc", override: true},
      {:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr", override: true},
      {:ex_qbootctl, github: "mlainez/ex_qbootctl", override: true},
      {:ex_audio, github: "mlainez/ex_audio", override: true},
      {:fp3_camera, github: "mlainez/fp3_camera", override: true},
      {:qmi, github: "mlainez/qmi", branch: "qrtr-transport", override: true},
      {:vintage_net_qmi,
       github: "mlainez/vintage_net_qmi", branch: "qrtr-transport", override: true},
      {:fp3_modem, github: "mlainez/fp3_modem", override: true},
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

  # A sibling comes from a local checkout when its *_PATH variable is set,
  # from GitHub otherwise.
  defp sibling(app, env) do
    case System.get_env(env) do
      path when path in [nil, ""] -> {app, github: "mlainez/#{app}", override: true}
      path -> {app, path: path, override: true}
    end
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
