defmodule ExAST.CLI.Output do
  @moduledoc false

  @stdout_key {__MODULE__, :stdout}

  def with_stdout(fun) when is_function(fun, 0) do
    if real_stdout?() do
      with_fd_stdout(fun)
    else
      with_io_stdout(fun)
    end
  end

  def puts(value \\ "") do
    write([to_string(value), "\n"])
  end

  def write(chardata) do
    case Process.get(@stdout_key) do
      nil -> IO.write(chardata)
      port -> port_write(port, chardata)
    end
  end

  def inspect(term, opts \\ []) do
    term
    |> Kernel.inspect(opts)
    |> puts()
  end

  defp with_fd_stdout(fun) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      port = Port.open({:fd, 0, 1}, [:out, :binary])
      previous_stdout = Process.get(@stdout_key)
      Process.put(@stdout_key, port)

      try do
        fun.()
      catch
        :closed_stdout -> :ok
      after
        restore_stdout(previous_stdout)
        close_port(port)
      end
    rescue
      ArgumentError -> with_io_stdout(fun)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp with_io_stdout(fun) do
    fun.()
  rescue
    error in ErlangError ->
      if error.original == :terminated do
        :ok
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp real_stdout? do
    Process.group_leader() == Process.whereis(:user)
  end

  defp port_write(port, chardata) do
    Port.command(port, IO.chardata_to_string(chardata))
    :ok
  rescue
    ArgumentError -> throw(:closed_stdout)
  catch
    :exit, _reason -> throw(:closed_stdout)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp restore_stdout(nil), do: Process.delete(@stdout_key)
  defp restore_stdout(previous), do: Process.put(@stdout_key, previous)
end
