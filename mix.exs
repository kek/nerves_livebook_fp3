defmodule NervesLivebookFP3.MixProject do
  use Mix.Project

  @app :nerves_livebook_fp3
  @version "0.2.0"

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
          # The whisper_cpp Rust NIF cross-compiles with the Nerves
          # toolchain, which is on PATH while dependencies compile. whisper-rs-sys
          # uses its bundled bindings instead of generating them with libclang.
          {"CARGO_BUILD_TARGET", "aarch64-unknown-linux-gnu"},
          {"CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER", "aarch64-nerves-linux-gnu-gcc"},
          {"WHISPER_DONT_GENERATE_BINDINGS", "1"},
          # nx_eigen uses Eigen's own FFT, so the target needs no FFTW library.
          {"NX_EIGEN_FFT_LIB", "eigen"}
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
        # At boot: first-boot data partition grow.
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
      # emerge needs rustler_precompiled ~> 0.8.4; whisper_cpp now wants
      # ~> 0.9.0. Force the older one — arm_ai, the other user, accepts
      # ~> 0.8 too.
      {:rustler_precompiled, "~> 0.8.4", override: true},

      # ---------------- AI stack ----------------
      # nerves_ai composes the stack. The engine packages are built for the
      # phone only.
      sibling(:nerves_ai, "NERVES_AI_PATH"),
      sibling(:nerves_data_resize, "NERVES_DATA_RESIZE_PATH"),
      {:llama_cpp_ex, "~> 0.8", targets: :nerves_system_fp3},
      {:whisper_cpp, "~> 0.5", targets: :nerves_system_fp3},
      {:evision, "~> 1.0.1-rc.0", targets: :nerves_system_fp3},
      # Fast Nx on the phone (Eigen with NEON). evision declares `nx ~> 0.12.1`
      # but works with Nx 1.0; nx_eigen needs Nx 1.0.
      {:nx, "~> 1.0", override: true},
      # `env: :dev` makes nx_eigen build from source with the Nerves toolchain:
      # its precompiled aarch64 NIF links FFTW, which the system image lacks.
      {:nx_eigen, "~> 0.2", targets: :nerves_system_fp3, env: :dev},
      # Builds whisper_cpp from source.
      {:rustler, "~> 0.38.0", runtime: false},

      # ---------------- FP3 hardware userspace ----------------
      {:ex_rmtfs, github: "mlainez/ex_rmtfs"},
      {:ex_remoteproc, github: "mlainez/ex_remoteproc", override: true},
      {:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr", override: true},
      {:ex_qbootctl, github: "mlainez/ex_qbootctl", override: true},
      sibling(:ex_audio, "EX_AUDIO_PATH"),
      sibling(:fp3_camera, "FP3_CAMERA_PATH"),
      {:qmi, github: "mlainez/qmi", branch: "qrtr-transport", override: true},
      # Forks with fixes for two modem boot races and a power-off mode
      # the modem can't leave without a reset, until the upstream PRs
      # are merged (not yet, as of nerves_system_fp3 v0.3.0).
      {:vintage_net_qmi, github: "kek/vintage_net_qmi", branch: "fix-boot-races", override: true},
      {:fp3_modem, github: "kek/fp3_modem", branch: "low-power-off", override: true},
      sibling(:ex_nfc, "EX_NFC_PATH"),
      {:ex_location, github: "mlainez/ex_location", override: true},
      {:blue_heron, github: "mlainez/blue_heron", targets: :nerves_system_fp3},

      # ---------------- The nerves_system_fp3 ----------------
      # The prebuilt system normally comes from the tag's GitHub release.
      # `nerves: [compile: true]` forces a local Buildroot build instead, so
      # deps/nerves_system_fp3/local.mk's LINUX_OVERRIDE_SRCDIR (a patched
      # kernel checkout) actually gets used instead of being silently
      # ignored in favor of the matching prebuilt release.
      {:nerves_system_fp3,
       github: "mlainez/nerves_system_fp3",
       tag: "v0.3.0",
       runtime: false,
       targets: :nerves_system_fp3,
       nerves: [compile: true]}
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
