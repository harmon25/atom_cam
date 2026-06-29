defmodule AtomCam.MixProject do
  use Mix.Project

  def project do
    [
      app: :atom_cam,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [
        start: AtomCam,
        flash_offset: 0x250000
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exatomvm, github: "atomvm/ExAtomVM", runtime: false},
      {:wifi_wiz, github: "harmon25/wifi_wiz", branch: "main"},
      {:esp32cam, github: "petermm/atomvm_esp32cam", branch: "multiple_boards"},
      {:atomvm_httpd, github: "harmon25/atomvm_httpd", branch: "main"}
    ]
  end
end
