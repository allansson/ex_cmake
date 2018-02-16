defmodule ExCmakeTest do
  use ExUnit.Case
  doctest ExCmake

  test "greets the world" do
    assert ExCmake.hello() == :world
  end
end
