defmodule Mix.Tasks.Compile.Cmake do
  use Mix.Task.Compiler

  require Logger

  defmodule Paths do
    defstruct cmake: nil, source_dir: nil, build_dir: nil, target_dir: nil, target_path: nil
  end

  defp get_cmake_compiler() do
    case System.find_executable("cmake") do
      nil ->
        {:error, :cmake_not_found}

      path ->
        {:ok, path}
    end
  end

  defp get_current_platform() do
    case :os.type() do
      {:win32, _} ->
        :win32

      {:unix, platform} ->
        platform
    end
  end

  defp get_definitions_for_platform(definitions, target_platform) do
    {supported, not_supported} =
      Enum.reduce(definitions, {[], []}, fn {source_dir, platforms, opts},
                                            {supported, not_supported} ->
        case Keyword.get(platforms, target_platform) do
          nil ->
            {supported, [source_dir | not_supported]}

          outputs ->
            {[{source_dir, outputs, opts} | supported], not_supported}
        end
      end)

    case not_supported do
      [] ->
        {:ok, supported}

      _ ->
        {:error, :no_output_for_platform, target_platform, not_supported}
    end
  end

  defp get_cmake_definitions() do
    Mix.Project.get!()
    |> apply(:project, [])
    |> Keyword.get(:cmake, [])
  end

  defp get_build_dir(source_dir, opts),
    do: Keyword.get(opts, :build_dir, Path.join(source_dir, "build"))

  defp get_target_path(output_file, opts),
    do:
      Path.join(
        Keyword.get(opts, :output_dir, Path.join(Mix.Project.app_path(), "priv/lib")),
        output_file
      )

  defp build_error(file, message, position \\ nil, details \\ ""),
    do: %Mix.Task.Compiler.Diagnostic{
      compiler_name: :cmake,
      severity: :error,
      file: file,
      message: message,
      details: details,
      position: position
    }

  def run(_) do
    definitions = get_cmake_definitions()
    target_platform = get_current_platform()

    with {:ok, cmake_path} <- get_cmake_compiler(),
         {:ok, platform_definitions} <- get_definitions_for_platform(definitions, target_platform),
         {:ok, build_artifacts} <- build_all_projects(cmake_path, platform_definitions),
         {:ok, _} <- copy_build_artifacts(build_artifacts) do
      :ok
    else
      {:error, :cmake_not_found} ->
        {:error,
         [
           build_error(
             nil,
             "Could not find path to cmake executable. Make sure it is installed and available on your PATH."
           )
         ]}

      {:error, :no_output_for_platform, _target_platform, projects} ->
        to_error = fn project ->
          build_error(
            project,
            "Could not build '#{project}' because it does not have any outputs defined for the current platform."
          )
        end

        {:error,
         projects
         |> Enum.map(to_error)}

      {:error, :build_error, build_errors} ->
        {:error, build_errors}

      {:error, :failed_to_copy_files, failed_files} ->
        to_error = fn {err, target_path, output_path} ->
          build_error(
            target_path,
            "Could not copy file '#{target_path}' to '#{output_path}'. The error was #{err}."
          )
        end

        {:error,
         failed_files
         |> Enum.map(to_error)}
    end
  end

  def clean() do
    definitions = get_cmake_definitions()
    target_platform = get_current_platform()

    with {:ok, platform_definitions} <- get_definitions_for_platform(definitions, target_platform) do
      Enum.each(platform_definitions, &clean/1)
    end
  end

  def clean({source_dir, outputs, opts}) do
    build_dir = get_build_dir(source_dir, opts)
    target_path = get_target_path(outputs, opts)

    File.rm(target_path)
    File.rm_rf(build_dir)
  end

  defp build_all_projects(cmake_path, definitions) do
    result =
      Enum.reduce(definitions, {[], []}, fn definition, {succeded, failed} ->
        case build(cmake_path, definition) do
          {:ok, artifacts} ->
            {artifacts ++ succeded, failed}

          errors ->
            {succeded, errors ++ errors}
        end
      end)

    case result do
      {succeeded, []} ->
        {:ok, succeeded}

      {_, errors} ->
        {:error, :build_error, errors}
    end
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

        {:ok, []}

      _ ->
        Mix.shell().info("Building '#{output}' from CMake project in '#{dir}'")

        File.rm(target_path)
        File.rm_rf(build_dir)
        File.mkdir_p(build_dir)

        with :ok <- generate_build_files(cmake_path, build_dir, source_dir, vars, env),
             :ok <- build_project(cmake_path, build_dir, config, env) do
          case :filelib.wildcard('**/#{output}', to_charlist(build_dir)) do
            [output_file] ->
              {:ok, [{Path.join(build_dir, output_file), target_path}]}

            [] ->
              {:error, :build_error,
               build_error(
                 output,
                 "Could not find expected output '#{output}' among the artifacts build for project '#{
                   dir
                 }'."
               )}

            [_first, _second | _rest] ->
              {:error, :build_error,
               build_error(
                 output,
                 "Found multiple files matching expected output '#{output}' after building project '#{
                   dir
                 }'"
               )}
          end
        else
          {:error, :build, exit_status} ->
            [
              {:error, :build_error,
               build_error(
                 source_dir,
                 "Failed to build project '#{dir}'. The exit status was #{exit_status}."
               )}
            ]

          {:error, :generate, exit_status} ->
            [
              {:error, :build_error,
               build_error(
                 source_dir,
                 "Failed to generate build files for project '#{dir}'. The exit status was #{
                   exit_status
                 }."
               )}
            ]
        end
    end
  end

  defp generate_build_files(cmake_path, build_dir, source_dir, vars, env) do
    args = [vars, source_dir] |> List.flatten()

    case run_cmake(cmake_path, build_dir, args, env) do
      0 ->
        :ok

      {:error, non_zero_exit_status} ->
        {:error, :generate, non_zero_exit_status}
    end
  end

  defp build_project(cmake_path, build_dir, config, env) do
    config_args =
      if config != nil do
        ["--config", config]
      else
        []
      end

    args = ["--build", build_dir, "--clean-first", config_args] |> List.flatten()

    case run_cmake(cmake_path, build_dir, args, env) do
      0 ->
        :ok

      {:error, non_zero_exit_status} ->
        {:error, :build, non_zero_exit_status}
    end
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

  defp copy_build_artifacts(artifacts) do
    result =
      Enum.reduce(artifacts, {[], []}, fn {artifact_path, output_path}, {succeeded, failed} ->
        File.mkdir_p(Path.dirname(output_path))

        case File.copy(artifact_path, output_path) do
          {:ok, _} ->
            {[output_path | succeeded], failed}

          {:error, error} ->
            {succeeded, [{error, artifact_path, output_path} | failed]}
        end
      end)

    case result do
      {copied, []} ->
        {:ok, copied}

      {_, failed} ->
        {:error, :failed_to_copy_files, failed}
    end
  end
end