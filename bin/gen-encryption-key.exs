#!/usr/bin/env elixir

32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> IO.puts()
