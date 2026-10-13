defmodule Garden.WorkStore.Narinfo do
  @moduledoc false
  use TypedStruct

  typedstruct do
    field :path, String.t(), enforce: true
    field :url, String.t(), enforce: true
    field :nar_size, non_neg_integer(), enforce: true
    field :file_size, non_neg_integer(), enforce: true
    field :references, [String.t()], enforce: true
    field :fields, map(), enforce: true
  end

  @path ~r|\A/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+\z|
  @nar ~r"\Anar/[0123456789abcdfghijklmnpqrsvwxyz]{52}\.nar(?:\.(?:xz|bz2|gz|zst|lz|lz4|br))?\z"
  @info ~r|\A[0123456789abcdfghijklmnpqrsvwxyz]{32}\.narinfo\z|
  def path?(value), do: is_binary(value) and Regex.match?(@path, value)
  def nar?(value), do: is_binary(value) and Regex.match?(@nar, value)
  def info?(value), do: is_binary(value) and Regex.match?(@info, value)
  def key(path), do: path |> Path.basename() |> binary_part(0, 32) |> Kernel.<>(".narinfo")

  def parse(bytes, key) when byte_size(bytes) <= 65_536 do
    rows = String.split(bytes, "\n", trim: true)
    pairs = Enum.map(rows, &String.split(&1, ": ", parts: 2))

    if Enum.all?(pairs, &(length(&1) == 2)) do
      pairs = Enum.reject(pairs, fn [name, _] -> name == "Sig" end)
      fields = Map.new(pairs, fn [name, value] -> {name, value} end)
      path = fields["StorePath"]

      refs =
        String.split(fields["References"] || "", " ", trim: true)
        |> Enum.map(&("/nix/store/" <> &1))

      with true <- map_size(fields) == length(pairs),
           true <- path?(path) and key(path) == key,
           true <- nar?(fields["URL"]),
           true <-
             fields["Compression"] in [
               "none",
               "xz",
               "bzip2",
               "gzip",
               "zstd",
               "lzip",
               "lz4",
               "brotli",
               "br",
               "compress",
               "grzip",
               "lrzip",
               "lzma",
               "lzop"
             ],
           true <- Enum.all?(refs, &path?/1),
           true <- hash?(fields["NarHash"]) and hash?(fields["FileHash"]),
           true <-
             String.starts_with?(
               fields["URL"],
               "nar/" <> String.replace_prefix(fields["FileHash"], "sha256:", "") <> ".nar"
             ),
           {nar_size, ""} when nar_size > 0 <- Integer.parse(fields["NarSize"] || ""),
           {file_size, ""} when file_size > 0 <- Integer.parse(fields["FileSize"] || "") do
        {:ok,
         %__MODULE__{
           path: path,
           url: fields["URL"],
           nar_size: nar_size,
           file_size: file_size,
           references: refs,
           fields: fields
         }}
      else
        _ -> {:error, :invalid_narinfo}
      end
    else
      {:error, :invalid_narinfo}
    end
  end

  def parse(_, _), do: {:error, :invalid_narinfo}

  defp hash?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\Asha256:[0123456789abcdfghijklmnpqrsvwxyz]{52}\z/, value)
end
