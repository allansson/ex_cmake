defmodule Mix.Tasks.Compile.Cmake do
  use Mix.Task

  require Logger

  def run(_) do
    cmake_path = System.find_executable("cmake")

    if cmake_path == nil do
      raise Mix.Error,
        message:
          "Could not find 'cmake'. Make sure it is installed before compiling this project."
    end

    project =
      Mix.Project.get!()
      |> apply(:project, [])

    os = current_os()

    cmake_defs =
      Keyword.get(project, :cmake, [])
      |> Enum.map(&get_os_specific(os, &1))

    Enum.each(cmake_defs, &build(cmake_path, &1))
  end

  defp build(cmake_path, {dir, output, opts}) do
    env =
      Keyword.get(opts, :env, [])
      |> Enum.map(fn {name, value} -> {Atom.to_charlist(name), Atom.to_charlist(value)} end)

    vars =
      Keyword.get(opts, :vars, [])
      |> Enum.map(fn
        {name, type, value} -> "-D#{name}:#{type}=#{value}"
        {name, value} -> "-D#{name}=#{value}"
      end)

    config = Keyword.get(opts, :config, nil)

    source_dir = Path.join(File.cwd!(), dir)
    build_dir = Keyword.get(opts, :build_dir, Path.join(source_dir, "build"))
    output_dir = Path.join(Mix.Project.app_path(), "priv/lib")
    target_path = Path.join(output_dir, output)

    source_files = Mix.Utils.extract_files([source_dir], "*")

    case Mix.Utils.extract_stale(source_files, [target_path]) do
      [] ->
        Mix.shell().info("Target file '#{output}' has already been built.")

        :noop

      _ ->
        Mix.shell().info("Building '#{output}' from CMake project in '#{dir}'")

        File.rm(target_path)
        File.rm_rf(build_dir)
        File.mkdir_p(build_dir)

        with {:generate, 0} <- generate_build_files(cmake_path, build_dir, source_dir, vars, env),
             {:build, 0} <- build_project(cmake_path, build_dir, config, env) do
          case :filelib.wildcard('**/#{output}', to_charlist(build_dir)) do
            [] ->
              raise Mix.Error,
                message:
                  "Could not find expected output file #{output} after successfully building '#{
                    dir
                  }'."

            [output_file] ->
              Mix.shell().info("Copying '#{output_file}' to '#{output_dir}'")

              File.cp!(Path.join(build_dir, output_file), target_path)

            [_first, _second | _rest] ->
              raise Mix.Error,
                message: "Building '#{dir}' produced multiple output files with name '#{output}'."
          end
        else
          {:generate, exit_status} ->
            raise Mix.Error,
              message:
                "Failed to generate build files for '#{dir}'. The exit status was #{exit_status}."

          {:build, exit_status} ->
            raise Mix.Error,
              message: "Failed to build project for '#{dir}'. The exit status was #{exit_status}."
        end
    end
  end

  defp generate_build_files(cmake_path, build_dir, source_dir, vars, env) do
    args = [vars, source_dir] |> List.flatten()

    {:generate, run_cmake(cmake_path, build_dir, args, env)}
  end

  defp build_project(cmake_path, build_dir, config, env) do
    config_args =
      if config != nil do
        ["--config", config]
      else
        []
      end

    args = ["--build", build_dir, "--clean-first", config_args] |> List.flatten()

    {:build, run_cmake(cmake_path, build_dir, args, env)}
  end

  defp run_cmake(cmake_path, cwd, args, env) do
    port =
      Port.open({:spawn_executable, cmake_path}, [
        :stream,
        :binary,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        :exit_status,
        {:cd, cwd},
        {:env, env},
        {:args, args}
      ])

    handle_port(port)
  end

  defp handle_port(port) do
    receive do
      {^port, {:data, data}} ->
        Logger.debug(data)
        handle_port(port)

      {^port, {:exit_status, exit_status}} ->
        exit_status
    end
  end

  defp get_os_specific(os, {dir, outputs}), do: os_specific(os, {dir, outputs, []})

  defp get_os_specific(os, {dir, outputs, opts})
       when is_binary(dir) and is_list(outputs) and is_list(opts) do
    case Keyword.get(outputs, os) do
      nil ->
        raise Mix.Error,
          message:
            "Cannot build project on platform #{os} because no output has been defined for it. To resolve this, define an output for #{
              os
            } in your Mix.exs"

      val ->
        {dir, val, opts}
    end
  end

  defp os_specific(_os, entry),
    do:
      raise(
        Mix.Error,
        message:
          "Malformed cmake definition #{inspect(entry)}. Definitions must be a 2 or 3-value tuple, e.g. {\"mycmakelib\", [linux: \"mycmakelib.so\"], vars: [SOME_VAR: :OVER_THE_RAINBOW]}"
      )

  defp current_os() do
    case :os.type() do
      {:win32, _} ->
        :win32

      {:unix, "Linux"} ->
        :linux

      {:unix, "Darwin"} ->
        :osx
    end
  end
end