defmodule ReyCode.TUI.AnimationClock do
  @moduledoc "TUI-local single-timer clock; it never touches durable state."

  @frame_ms 120
  @reduced_motion_frame_ms 1_000

  @enforce_keys [:reduced_motion?, :schedule, :cancel]
  defstruct token: nil,
            timer_ref: nil,
            frame_index: 0,
            reduced_motion?: false,
            schedule: nil,
            cancel: nil

  @type schedule :: (reference(), pos_integer() -> term())
  @type cancel :: (term() -> term())
  @type t :: %__MODULE__{
          token: reference() | nil,
          timer_ref: term() | nil,
          frame_index: non_neg_integer(),
          reduced_motion?: boolean(),
          schedule: schedule(),
          cancel: cancel()
        }

  @doc "Creates an idle clock with injectable timer adapters."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      reduced_motion?: Keyword.get(opts, :reduced_motion?, false),
      schedule: Keyword.fetch!(opts, :schedule),
      cancel: Keyword.fetch!(opts, :cancel)
    }
  end

  @doc "Starts or stops the one timer to match current active-work state."
  @spec reconcile(t(), boolean()) :: t()
  def reconcile(%__MODULE__{token: nil} = clock, true), do: arm(clock)
  def reconcile(%__MODULE__{} = clock, true), do: clock
  def reconcile(%__MODULE__{} = clock, false), do: stop(clock)

  @doc "Handles one timer token, advancing/rearming only when current and active."
  @spec tick(t(), reference(), boolean()) :: {:ok, t()} | :stale
  def tick(%__MODULE__{token: token} = clock, token, active?) when not is_nil(token) do
    clock = %{
      clock
      | token: nil,
        timer_ref: nil,
        frame_index: advance_frame(clock)
    }

    {:ok, reconcile(clock, active?)}
  end

  def tick(%__MODULE__{}, _token, _active?), do: :stale

  @doc "Cancels the pending timer and returns an idle clock."
  @spec stop(t()) :: t()
  def stop(%__MODULE__{token: nil} = clock), do: clock

  def stop(%__MODULE__{} = clock) do
    _cancelled = clock.cancel.(clock.timer_ref)
    %{clock | token: nil, timer_ref: nil}
  end

  @doc "The current shared frame index."
  @spec frame_index(t()) :: non_neg_integer()
  def frame_index(%__MODULE__{frame_index: index}), do: index

  @doc "The configured cadence with units."
  @spec frame_ms(t()) :: pos_integer()
  def frame_ms(%__MODULE__{reduced_motion?: true}), do: @reduced_motion_frame_ms
  def frame_ms(%__MODULE__{}), do: @frame_ms

  @doc "Whether the clock currently owns a timer."
  @spec armed?(t()) :: boolean()
  def armed?(%__MODULE__{token: token}), do: not is_nil(token)

  defp arm(clock) do
    token = make_ref()
    timer_ref = clock.schedule.(token, frame_ms(clock))
    %{clock | token: token, timer_ref: timer_ref}
  end

  defp advance_frame(%__MODULE__{reduced_motion?: true, frame_index: index}), do: index
  defp advance_frame(%__MODULE__{frame_index: index}), do: index + 1
end
