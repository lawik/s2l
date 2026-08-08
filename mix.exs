defmodule S2l.MixProject do
  use Mix.Project

  def project do
    [
      app: :s2l,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: make_error_message(),
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "S2l",
      description: "TODO: write a proper description",
      docs: docs(),
      package: package(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  def package do
    [
      name: :s2l,
      licenses: ["GPL-3.0-or-later"],
      files: ~w(lib c_src Makefile mix.exs README.md LICENSE.md CHANGELOG.md .formatter.exs),
      links: %{"GitHub" => "https://github.com/TODO/s2l"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp make_error_message do
    """
    Could not build the aubio NIF.

    aubio is downloaded and compiled from source as part of this build, so no
    system libaubio is required. What is required is a C compiler, make, tar,
    and either curl or wget for the initial download.

    The download happens once and is cached under _build. To build without
    network access, supply the source yourself:

      AUBIO_TARBALL=/path/to/aubio-0.4.9.tar.bz2 mix compile
      AUBIO_SOURCE_DIR=/path/to/aubio-0.4.9 mix compile
    """
  end

  def aliases do
    [
      check: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format --check-formatted",
        "credo --strict",
        "deps.unlock --check-unused",
        "spellweaver.check",
        "dialyzer"
      ],
      precommit: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format",
        "credo --strict",
        "deps.unlock --unused",
        "spellweaver.check",
        "dialyzer",
        "test"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  def dialyzer do
    [
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:membrane_core, "~> 1.3"},
      {:membrane_raw_audio_format, "~> 0.12"},
      {:nstandard, "~> 0.5", runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:spellweaver, "~> 0.1.8", only: [:dev, :test], runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
