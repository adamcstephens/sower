defmodule SowerWeb.ThemeTest do
  use ExUnit.Case, async: true

  @web_root Path.expand("../../lib/sower_web", __DIR__)
  @assets_root Path.expand("../../assets", __DIR__)

  @palettes [
    "slate",
    "gray",
    "zinc",
    "neutral",
    "stone",
    "red",
    "orange",
    "amber",
    "yellow",
    "lime",
    "green",
    "emerald",
    "teal",
    "cyan",
    "sky",
    "blue",
    "indigo",
    "violet",
    "purple",
    "fuchsia",
    "pink",
    "rose"
  ]

  @tokens [
    "canvas",
    "surface",
    "surface-hover",
    "surface-active",
    "hairline",
    "line",
    "line-strong",
    "content",
    "content-strong",
    "content-muted",
    "content-subtle",
    "accent",
    "accent-link",
    "accent-solid",
    "accent-solid-fg",
    "control",
    "control-fg",
    "ok",
    "ok-mark",
    "ok-surface",
    "info",
    "info-mark",
    "info-surface",
    "warn",
    "warn-mark",
    "danger",
    "danger-mark",
    "danger-surface",
    "danger-solid",
    "danger-solid-hover"
  ]

  defp web_sources do
    Path.wildcard(Path.join(@web_root, "**/*.{ex,heex}"))
  end

  defp offending_lines(path, regex) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, idx} ->
      "#{Path.relative_to(path, @web_root)}:#{idx}: #{String.trim(line)}"
    end)
  end

  test "no raw palette color utilities remain in sower_web" do
    regex =
      ~r/\b(?:bg|text|border|ring|divide|fill|stroke|from|via|to|placeholder|outline|shadow|decoration|accent|caret)-(?:#{Enum.join(@palettes, "|")})-\d{2,3}\b/

    offenders = Enum.flat_map(web_sources(), &offending_lines(&1, regex))

    assert offenders == [],
           "raw palette utilities must be replaced with semantic tokens:\n" <>
             Enum.join(offenders, "\n")
  end

  test "no bare white or black color utilities remain in sower_web" do
    regex = ~r/\b(?:bg|text|border|ring|divide|fill|stroke)-(?:white|black)\b/

    offenders = Enum.flat_map(web_sources(), &offending_lines(&1, regex))

    assert offenders == [],
           "bare white/black utilities must be replaced with semantic tokens:\n" <>
             Enum.join(offenders, "\n")
  end

  test "no dark: variants remain in sower_web" do
    offenders = Enum.flat_map(web_sources(), &offending_lines(&1, ~r/\bdark:/))

    assert offenders == [],
           "semantic tokens carry both schemes, so dark: variants are redundant:\n" <>
             Enum.join(offenders, "\n")
  end

  describe "app.css" do
    setup do
      %{css: File.read!(Path.join(@assets_root, "css/app.css"))}
    end

    test "defines every token for the light scheme", %{css: css} do
      missing = Enum.reject(@tokens, &String.contains?(css, "--color-#{&1}:"))
      assert missing == []
    end

    test "defines every token for the dark scheme", %{css: css} do
      [_, dark] = String.split(css, "@media (prefers-color-scheme: dark)", parts: 2)
      missing = Enum.reject(@tokens, &String.contains?(dark, "--color-#{&1}:"))
      assert missing == []
    end

    test "carries no scheme-specific selector left over from a class strategy", %{css: css} do
      refute css =~ ".dark "
    end

    test "hardcodes no literal colors outside the token definitions", %{css: css} do
      [_, rules] = String.split(css, "/* end tokens */", parts: 2)
      refute rules =~ ~r/rgb\(\s*\d|#[0-9a-fA-F]{3,8}\b/
    end
  end

  describe "tailwind.config.js" do
    setup do
      %{config: File.read!(Path.join(@assets_root, "tailwind.config.js"))}
    end

    test "exposes every token as a color", %{config: config} do
      missing = Enum.reject(@tokens, &String.contains?(config, "var(--color-#{&1})"))
      assert missing == []
    end

    test "scans no content globs for absent dependencies", %{config: config} do
      refute config =~ "ash_authentication_phoenix"
    end
  end

  describe "contrast" do
    @text_pairs [
      {"content", "canvas"},
      {"content", "surface"},
      {"content", "surface-hover"},
      {"content-strong", "canvas"},
      {"content-muted", "canvas"},
      {"content-muted", "surface"},
      {"content-subtle", "canvas"},
      {"content-subtle", "surface"},
      {"accent-link", "canvas"},
      {"control-fg", "control"},
      {"accent-solid-fg", "accent-solid"},
      {"accent-solid-fg", "danger-solid"},
      {"accent-solid-fg", "danger-solid-hover"},
      {"ok", "canvas"},
      {"ok", "ok-surface"},
      {"info", "canvas"},
      {"info", "info-surface"},
      {"warn", "canvas"},
      {"danger", "canvas"},
      {"danger", "danger-surface"}
    ]

    @control_pairs [
      {"line-strong", "canvas"},
      {"line-strong", "surface"}
    ]

    setup do
      css = File.read!(Path.join(@assets_root, "css/app.css"))
      [light, dark] = String.split(css, "@media (prefers-color-scheme: dark)", parts: 2)
      %{light: parse_scheme(light), dark: parse_scheme(dark)}
    end

    test "body text meets WCAG AA in both schemes", schemes do
      assert_pairs(schemes, @text_pairs, 4.5)
    end

    test "control borders meet the 3:1 non-text threshold in both schemes", schemes do
      assert_pairs(schemes, @control_pairs, 3.0)
    end
  end

  defp parse_scheme(css) do
    ~r/--color-([a-z-]+): (\d+) (\d+) (\d+);/
    |> Regex.scan(css)
    |> Map.new(fn [_, token, r, g, b] ->
      {token, {String.to_integer(r), String.to_integer(g), String.to_integer(b)}}
    end)
  end

  defp assert_pairs(schemes, pairs, threshold) do
    failures =
      for {fg, bg} <- pairs,
          {scheme, tokens} <- [{"light", schemes.light}, {"dark", schemes.dark}],
          ratio = contrast(Map.fetch!(tokens, fg), Map.fetch!(tokens, bg)),
          ratio < threshold do
        "#{scheme}: #{fg} on #{bg} is #{Float.round(ratio, 2)}:1, needs #{threshold}:1"
      end

    assert failures == [], Enum.join(failures, "\n")
  end

  defp contrast(fg, bg) do
    [dark, light] = Enum.sort([relative_luminance(fg), relative_luminance(bg)])
    (light + 0.05) / (dark + 0.05)
  end

  defp relative_luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn channel ->
      c = channel / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> Enum.zip([0.2126, 0.7152, 0.0722])
    |> Enum.map(fn {c, weight} -> c * weight end)
    |> Enum.sum()
  end
end
