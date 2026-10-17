defmodule NervesLivebookFP3 do
  @moduledoc """
  Workshop firmware for the Fairphone 3 / 3+, built on Nerves.

  Boots into a Livebook served on port 4000. The notebooks ship in
  `priv/samples`, are copied to `/data/livebook/notebooks` (writable) at
  boot and starred so they appear on Livebook's home page.

  Models are not in the firmware image: each AI notebook downloads the
  one it needs with `NervesAI.Models.ensure_one/3`.
  """
end
