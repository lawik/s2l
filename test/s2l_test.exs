defmodule S2lTest do
  use ExUnit.Case
  doctest S2l

  test "greets the world" do
    assert S2l.hello() == :world
  end
end
