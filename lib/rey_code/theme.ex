defmodule ReyCode.Theme do
  @moduledoc false

  def default do
    Breeze.Theme.new(
      name: "reycode",
      dark: true,
      defaults: %{
        text: "#D7DCE2",
        background: "#0B0E12",
        border: "#303741"
      },
      palette: %{
        muted: "#78838F",
        primary: "#7DD3A7",
        secondary: "#82AEEF",
        warning: "#E5C07B",
        error: "#E06C75",
        success: "#7DD3A7",
        accent: "#C792EA",
        surface: "#12171D",
        panel: "#181E26"
      },
      extras: %{cursor: "#F4F7FA"}
    )
  end
end
