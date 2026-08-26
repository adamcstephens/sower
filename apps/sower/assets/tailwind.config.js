// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin");
const fs = require("fs");
const path = require("path");

module.exports = {
	content: [
		"./js/**/*.js",
		"../lib/*_web.ex",
		"../lib/*_web/**/*.*ex",
	],
	theme: {
		extend: {
			colors: {
				"canvas": "rgb(var(--color-canvas) / <alpha-value>)",
				"surface": "rgb(var(--color-surface) / <alpha-value>)",
				"surface-hover": "rgb(var(--color-surface-hover) / <alpha-value>)",
				"surface-active": "rgb(var(--color-surface-active) / <alpha-value>)",
				"hairline": "rgb(var(--color-hairline) / <alpha-value>)",
				"line": "rgb(var(--color-line) / <alpha-value>)",
				"line-strong": "rgb(var(--color-line-strong) / <alpha-value>)",
				"content": "rgb(var(--color-content) / <alpha-value>)",
				"content-strong": "rgb(var(--color-content-strong) / <alpha-value>)",
				"content-muted": "rgb(var(--color-content-muted) / <alpha-value>)",
				"content-subtle": "rgb(var(--color-content-subtle) / <alpha-value>)",
				"accent": "rgb(var(--color-accent) / <alpha-value>)",
				"accent-link": "rgb(var(--color-accent-link) / <alpha-value>)",
				"accent-solid": "rgb(var(--color-accent-solid) / <alpha-value>)",
				"accent-solid-fg": "rgb(var(--color-accent-solid-fg) / <alpha-value>)",
				"control": "rgb(var(--color-control) / <alpha-value>)",
				"control-fg": "rgb(var(--color-control-fg) / <alpha-value>)",
				"ok": "rgb(var(--color-ok) / <alpha-value>)",
				"ok-mark": "rgb(var(--color-ok-mark) / <alpha-value>)",
				"ok-surface": "rgb(var(--color-ok-surface) / <alpha-value>)",
				"info": "rgb(var(--color-info) / <alpha-value>)",
				"info-mark": "rgb(var(--color-info-mark) / <alpha-value>)",
				"info-surface": "rgb(var(--color-info-surface) / <alpha-value>)",
				"warn": "rgb(var(--color-warn) / <alpha-value>)",
				"warn-mark": "rgb(var(--color-warn-mark) / <alpha-value>)",
				"danger": "rgb(var(--color-danger) / <alpha-value>)",
				"danger-mark": "rgb(var(--color-danger-mark) / <alpha-value>)",
				"danger-surface": "rgb(var(--color-danger-surface) / <alpha-value>)",
				"danger-solid": "rgb(var(--color-danger-solid) / <alpha-value>)",
				"danger-solid-hover": "rgb(var(--color-danger-solid-hover) / <alpha-value>)",
			},
		},
	},
	plugins: [
		require("@tailwindcss/forms"),
		// Allows prefixing tailwind classes with LiveView classes to add rules
		// only when LiveView classes are applied, for example:
		//
		//     <div class="phx-click-loading:animate-ping">
		//
		plugin(({ addVariant }) =>
			addVariant("phx-no-feedback", [
				".phx-no-feedback&",
				".phx-no-feedback &",
			]),
		),
		plugin(({ addVariant }) =>
			addVariant("phx-click-loading", [
				".phx-click-loading&",
				".phx-click-loading &",
			]),
		),
		plugin(({ addVariant }) =>
			addVariant("phx-submit-loading", [
				".phx-submit-loading&",
				".phx-submit-loading &",
			]),
		),
		plugin(({ addVariant }) =>
			addVariant("phx-change-loading", [
				".phx-change-loading&",
				".phx-change-loading &",
			]),
		),

		// Embeds Heroicons (https://heroicons.com) into your app.css bundle
		// See your `CoreComponents.icon/1` for more information.
		//
		plugin(function ({ matchComponents, theme }) {
			let iconsDir = path.join(__dirname, "./vendor/heroicons/optimized");
			let values = {};
			let icons = [
				["", "/24/outline"],
				["-solid", "/24/solid"],
				["-mini", "/20/solid"],
			];
			icons.forEach(([suffix, dir]) => {
				fs.readdirSync(path.join(iconsDir, dir)).map((file) => {
					let name = path.basename(file, ".svg") + suffix;
					values[name] = { name, fullPath: path.join(iconsDir, dir, file) };
				});
			});
			matchComponents(
				{
					hero: ({ name, fullPath }) => {
						let content = fs
							.readFileSync(fullPath)
							.toString()
							.replace(/\r?\n|\r/g, "");
						return {
							[`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
							"-webkit-mask": `var(--hero-${name})`,
							mask: `var(--hero-${name})`,
							"mask-repeat": "no-repeat",
							"background-color": "currentColor",
							"vertical-align": "middle",
							display: "inline-block",
							width: theme("spacing.5"),
							height: theme("spacing.5"),
						};
					},
				},
				{ values },
			);
		}),
	],
};
