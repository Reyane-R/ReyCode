defmodule Mix.Tasks.ReyCode.Store do
  @shortdoc "Verifies, backs up, or restores the event store"

  @moduledoc """
  Performs offline event-store maintenance.

      mix rey_code.store verify [--path DATABASE]
      mix rey_code.store checkpoint [--path DATABASE]
      mix rey_code.store backup DESTINATION [--path DATABASE]
      mix rey_code.store restore BACKUP [--path DATABASE] [--replace]
  """

  use Mix.Task

  alias ReyCode.StoreMaintenance

  @switches [path: :string, replace: :boolean]
  @requirements ["app.config"]

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: usage!()

    path = opts[:path] || ReyCode.Application.storage_paths().database

    result = operation(args, path, opts)

    case result do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("Store operation failed: #{inspect(reason)}")
    end
  end

  defp operation(["verify"], path, _opts), do: StoreMaintenance.verify(path)
  defp operation(["checkpoint"], path, _opts), do: StoreMaintenance.checkpoint(path)

  defp operation(["backup", destination], path, _opts),
    do: StoreMaintenance.backup(path, destination)

  defp operation(["restore", source], path, opts),
    do: StoreMaintenance.restore(source, path, replace: opts[:replace])

  defp operation(_args, _path, _opts), do: usage!()

  @spec usage!() :: no_return()
  defp usage! do
    Mix.raise(
      "Usage: mix rey_code.store verify [--path DATABASE] | " <>
        "checkpoint [--path DATABASE] | " <>
        "backup DESTINATION [--path DATABASE] | " <>
        "restore BACKUP [--path DATABASE] [--replace]"
    )
  end
end
