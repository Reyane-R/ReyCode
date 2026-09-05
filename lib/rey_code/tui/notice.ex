defmodule ReyCode.TUI.Notice do
  @moduledoc "Transient user feedback with explicit presentation severity."

  @enforce_keys [:severity, :message]
  defstruct [:severity, :message]

  @type severity :: :info | :success | :warning | :error
  @type t :: %__MODULE__{severity: severity(), message: String.t()}

  @spec new(severity(), String.t()) :: t()
  def new(severity, message)
      when severity in [:info, :success, :warning, :error] and is_binary(message),
      do: %__MODULE__{severity: severity, message: message}

  @spec text_class(t()) :: String.t()
  def text_class(%__MODULE__{severity: :info}), do: "text-primary"
  def text_class(%__MODULE__{severity: :success}), do: "text-success"
  def text_class(%__MODULE__{severity: :warning}), do: "text-warning"
  def text_class(%__MODULE__{severity: :error}), do: "text-error"

  @spec label(t()) :: String.t()
  def label(%__MODULE__{severity: :info}), do: "Info"
  def label(%__MODULE__{severity: :success}), do: "Success"
  def label(%__MODULE__{severity: :warning}), do: "Warning"
  def label(%__MODULE__{severity: :error}), do: "Error"
end
