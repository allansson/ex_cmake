# ExCMake

A Mix compiler for [CMake](https://cmake.org/).

## Prerequisites

CMake must be installed locally on the system before using. If it is not installed, the compiler will fail with an error.

## Installation

Add the compiler to your deps:

```elixir
def deps do
  [
    {:ex_cmake, "~> 0.1.0", runtime: false}
  ]
end
```

Then you can update your project to use the compiler:

```elixir
def project do
  [
    app: :ex_cmake,
    version: "0.1.0",
    elixir: "~> 1.6",
    compilers: [:cmake | Mix.compilers()]
    deps: deps()
  ]
end
```

## Usage

To define what the compiler should build, you need to provide a definition in your project:

```elixir
def project do
  [
    app: :ex_cmake,
    version: "0.1.0",
    elixir: "~> 1.6",
    compilers: [:cmake | Mix.compilers()]
    deps: deps(),
    cmake: cmake()
  ]
end
```

The `cmake` function is an arbitrary function name which returns a list of all CMake projects to build. It might look a bit like this:

```elixir
def cmake() do
  [
    {
      "libgit2",            
      [ # Keyword list of platform specific outputs
        win32: "libgit2.dll",
        linux: "libgit2.so",
        osx: "libgit2.dylib"
      ],
      [ # Additional options, e.g. CMake vars.
        vars: [
          LIBGIT2_FILENAME: "libgit2",
          BUILD_CLAR: :OFF
        ],
        config: :RELEASE
      ] 
    }
  ]
end
```

Supported platforms are currently `win32`, `linux` and `osx`. The platform is detected before running CMake using `:os.type()`.

The following additional options are supported:

| Option | Default | Description |
|--------|---------|-------------|
| vars    | []      | A list of variables to be passed to CMake using the `-D` option. Each variable can be a 2-value tuple with `{key, value}` or a 3-value tuple with `{key, type, value}`. All paramters can be either atoms or strings|
| env     | []      | A list of additional environment variables to be passed to CMake. Each variable has the form of a 2-value tuple, e.g. `{name, value}`. |
| build_dir | `Path.join(cmake_project_dir, "build")` | Path to the directory used for generated build files and build artifacts |

The built artifacts are put into the `priv/lib` of your compiled application, as per the recommended project structure for application (http://erlang.org/doc/design_principles/applications.html#7.4)
