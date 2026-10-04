import Config

# Enable the Nerves integration with Mix (required for target builds).
Application.start(:nerves_bootstrap)

# Reproducible builds: fixed timestamp for files in the firmware image.
config :nerves, source_date_epoch: "1700000000"

# Ship rootfs_overlay/ (/etc/iex.exs) in the image.
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Use shoehorn to start the main application. See the shoehorn
# documentation on hexdocs.pm/shoehorn for the full options.
config :shoehorn,
  init: [:nerves_runtime, :nerves_pack, :nerves_ai],
  app: Mix.Project.config()[:app]

# Use Ringlogger as the logger backend so the log buffer is
# available from `RingLogger.next/0` in iex / Livebook.
config :logger, backends: [RingLogger]

# Erlang's logger is configured by other libraries; tell it to
# defer formatting to our ring logger.
config :logger, RingLogger,
  max_size: 1024,
  application_levels: %{ssh: :error}

# Livebook reads its own config/config.exs defaults only when it's the
# root Mix project — as a dependency here, none of that applies, and
# several of its modules read compile-time config (Application.compile_env
# / fetch_env!) that would otherwise be missing entirely and crash
# `mix compile`. Replicate its defaults (deps/livebook/config/config.exs)
# so it boots the way it would standalone; our own overrides come after
# and take precedence per key.
config :livebook, LivebookWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost", path: "/"],
  pubsub_server: Livebook.PubSub,
  live_view: [signing_salt: "livebook"],
  drainer: [shutdown: 1000],
  render_errors: [formats: [html: LivebookWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, JSON

config :mime, :types, %{
  "audio/m4a" => ["m4a"],
  "text/plain" => ["livemd"]
}

config :livebook,
  agent_name: "default",
  allowed_uri_schemes: [],
  app_service_url: nil,
  apps_banner: nil,
  aws_credentials: false,
  feature_flags: [],
  force_ssl_host: nil,
  learn_notebooks: [],
  plugs: [],
  rewrite_on: [],
  shutdown_callback: nil,
  teams_auth: nil,
  teams_url: "https://teams.livebook.dev",
  github_release_info: %{repo: "livebook-dev/livebook", version: "0.19.10"},
  update_instructions_url: nil,
  within_iframe: false,
  k8s_kubeconfig_pipeline: Kubereq.Kubeconfig.Default

config :livebook, Livebook.Apps.Manager, retry_backoff_base_ms: 5_000

# Workshop-specific overrides — token-less (the device is the trust
# boundary; you have to be on the local network).
#
# default_runtime / default_app_runtime live in config/runtime.exs:
# Livebook.Runtime.Embedded.new() calls into :livebook, which isn't
# compiled yet when config.exs runs.
config :livebook,
  app_service_name: "nerves-livebook-fp3",
  authentication: :disabled,
  home: "/data/livebook/notebooks",
  apps_path: "/data/livebook/apps",
  cookie: :nerves_livebook_fp3

# Where the workshop notebooks live on disk. They ship in priv/samples;
# at boot any notebook not yet in /data/livebook/notebooks/ is copied
# there so it's writable and attendee edits are kept.
#
# erlinit mounts /dev/mmcblk0p62p3 (f2fs) at /root, and /data is a
# symlink to /root, so /data/... and /root/... are the same storage.
config :nerves_livebook_fp3, notebooks_dest: "/data/livebook/notebooks"

# At boot nerves_ai pins the VM's dirty schedulers to the fast cluster and
# runs the first-boot partition grow (configured below). No models are
# configured: the AI notebook fetches its models when the phone is online.

# Scenic's asset library (fonts); see lib/nerves_livebook_fp3/assets.ex.
config :scenic, :assets, module: NervesLivebookFP3.Assets

# First-boot grow of the /root partition and its F2FS, run once by the
# nerves_ai at boot (idempotent: the resizer reports :already_grown once the
# FS fills userdata). A phone
# flashed with fastboot keeps the image's partition size, so the
# partition itself is grown too, by the system's ops.fw grow-app task.
config :nerves_data_resize, :config,
  partition: "/dev/mmcblk0p62p3",
  mount_point: "/root",
  mount_opts: "nodev",
  grow_partition: [
    disk: "/dev/mmcblk0p62",
    ops_fw: "/usr/share/fwup/ops.fw",
    task: "grow-app"
  ]

import_config "#{Mix.target()}.exs"
