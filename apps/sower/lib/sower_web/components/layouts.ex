defmodule SowerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SowerWeb, :html

  @nav_items [
    %{section: :gardens, label: "Gardens", icon: "hero-squares-2x2"},
    %{section: :seeds, label: "Seeds", icon: "hero-sparkles"},
    %{section: :deployments, label: "Deployments", icon: "hero-rocket-launch"}
    # %{section: :forges, label: "Forges", icon: "hero-cube-transparent"},
    # %{section: :caches, label: "Nix caches", icon: "hero-server-stack"}
  ]

  @doc """
  Renders your app layout.

  ## Examples

      <Layouts.app
        flash={@flash}
        current_user={@current_user}
        nav_section={@nav_section}
        sidebar_state={@sidebar_state}
      >
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:current_user, :map, default: nil)
  attr(:nav_section, :atom, default: nil)
  attr(:sidebar_state, :atom, default: :expanded, values: [:expanded, :rail])
  attr(:crumbs, :list, default: [])

  slot(:inner_block, required: true)

  def app(assigns) do
    assigns = assign(assigns, :nav_items, @nav_items)

    ~H"""
    <div
      id="app-shell"
      data-sidebar={@sidebar_state}
      class="flex h-dvh bg-canvas text-content"
      phx-hook="SetCookie"
    >
      <.sidebar nav_section={@nav_section} nav_items={@nav_items} sidebar_state={@sidebar_state} />

      <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
        <.topbar
          current_user={@current_user}
          crumbs={resolve_crumbs(@crumbs, @nav_section)}
          nav_section={@nav_section}
          nav_items={@nav_items}
        />
        <main class="flex-1 overflow-auto">
          <div class="mx-auto w-full max-w-[1240px] px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
            <.auth_feedback flash={@flash} />
            <.flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  attr(:nav_section, :atom, required: true)
  attr(:nav_items, :list, required: true)
  attr(:sidebar_state, :atom, required: true)

  defp sidebar(assigns) do
    ~H"""
    <aside
      aria-label="Primary"
      class={[
        "hidden md:flex flex-col flex-shrink-0",
        "bg-canvas border-r border-hairline",
        "transition-[width] duration-200 ease-out overflow-hidden",
        @sidebar_state == :expanded && "w-[232px]",
        @sidebar_state == :rail && "w-14"
      ]}
    >
      <.sidebar_header expanded={@sidebar_state == :expanded} />
      <.sidebar_nav
        nav_section={@nav_section}
        nav_items={@nav_items}
        expanded={@sidebar_state == :expanded}
      />
      <div class="mt-auto flex-shrink-0">
        <.sidebar_version expanded={@sidebar_state == :expanded} />
        <.sidebar_toggle expanded={@sidebar_state == :expanded} />
      </div>
    </aside>
    """
  end

  attr(:expanded, :boolean, required: true)

  defp sidebar_version(assigns) do
    ~H"""
    <div
      :if={@expanded}
      class="px-4 pb-2 text-[11px] text-content-subtle tabular-nums tracking-tight"
    >
      v{server_version()}
    </div>
    """
  end

  defp server_version, do: to_string(Application.spec(:sower, :vsn))

  attr(:expanded, :boolean, required: true)

  defp sidebar_header(assigns) do
    ~H"""
    <div class={[
      "h-14 flex items-center gap-2 border-b border-hairline flex-shrink-0",
      @expanded && "px-4",
      not @expanded && "justify-center"
    ]}>
      <.glyph />
      <span :if={@expanded} class="text-sm font-semibold text-content-strong tracking-tight">
        Sower
      </span>
    </div>
    """
  end

  defp glyph(assigns) do
    ~H"""
    <span class="relative inline-flex items-center justify-center size-6" aria-hidden="true">
      <span class="bg-accent rotate-45 rounded-[2px] size-2.5" />
      <span class="bg-accent/40 absolute bottom-0 left-1/2 -translate-x-1/2 w-[18px] h-px" />
    </span>
    """
  end

  attr(:nav_section, :atom, required: true)
  attr(:nav_items, :list, required: true)
  attr(:expanded, :boolean, required: true)

  defp sidebar_nav(assigns) do
    ~H"""
    <nav
      aria-label="Sections"
      class={[
        "py-3 space-y-0.5 flex-shrink-0",
        @expanded && "px-3"
      ]}
    >
      <.sidebar_nav_item
        :for={item <- @nav_items}
        item={item}
        active={item.section == @nav_section}
        expanded={@expanded}
      />
    </nav>
    """
  end

  attr(:item, :map, required: true)
  attr(:active, :boolean, required: true)
  attr(:expanded, :boolean, required: true)

  defp sidebar_nav_item(assigns) do
    ~H"""
    <div :if={not @expanded} class="relative flex justify-center" title={@item.label}>
      <span
        :if={@active}
        class="absolute left-0 top-1 bottom-1 w-[2px] rounded-r-full bg-accent"
      />
      <.link
        navigate={nav_path(@item.section)}
        aria-current={@active && "page"}
        aria-label={@item.label}
        class={[
          "h-9 w-10 inline-flex items-center justify-center rounded-md",
          @active && "text-content-strong bg-surface-active",
          not @active && "text-content-muted hover:text-content-strong hover:bg-surface-hover"
        ]}
      >
        <.icon name={@item.icon} class="size-[17px]" />
      </.link>
    </div>
    <.link
      :if={@expanded}
      navigate={nav_path(@item.section)}
      aria-current={@active && "page"}
      class={[
        "relative flex items-center gap-3 px-3 py-2 rounded-md text-[13.5px]",
        @active && "bg-surface-active text-content-strong",
        not @active && "text-content-muted hover:text-content-strong hover:bg-surface-hover"
      ]}
    >
      <span
        :if={@active}
        class="absolute left-0 top-1.5 bottom-1.5 w-[2px] rounded-r-full bg-accent"
      />
      <.icon name={@item.icon} class="size-[15px] opacity-80" />
      <span class="flex-1">{@item.label}</span>
    </.link>
    """
  end

  attr(:expanded, :boolean, required: true)

  defp sidebar_toggle(assigns) do
    ~H"""
    <div class="border-t border-hairline py-2 flex justify-center">
      <button
        type="button"
        phx-click="toggle_sidebar"
        aria-label={if @expanded, do: "Collapse sidebar", else: "Expand sidebar"}
        class={[
          "h-8 inline-flex items-center justify-center rounded-md",
          "text-content-subtle hover:text-content-strong hover:bg-surface-hover",
          @expanded && "w-full mx-3",
          not @expanded && "w-10"
        ]}
      >
        <.icon
          name={if @expanded, do: "hero-chevron-left", else: "hero-chevron-right"}
          class="size-3.5"
        />
      </button>
    </div>
    """
  end

  attr(:current_user, :map, default: nil)
  attr(:crumbs, :list, required: true)
  attr(:nav_section, :atom, required: true)
  attr(:nav_items, :list, required: true)

  defp topbar(assigns) do
    ~H"""
    <header class="h-14 px-4 sm:px-5 flex items-center gap-3 border-b border-hairline flex-shrink-0">
      <.mobile_nav nav_section={@nav_section} nav_items={@nav_items} />

      <.crumbs crumbs={@crumbs} />

      <div class="flex-1" />

      <!--
      <button
        type="button"
        aria-label="Search"
        class="hidden lg:inline-flex items-center gap-2 h-8 w-[300px] px-3 rounded-md border border-hairline bg-surface text-[12.5px] text-content-subtle hover:border-line"
      >
        <.icon name="hero-magnifying-glass" class="size-3.5" />
        <span>Search gardens, seeds, deploys…</span>
        <span class="ml-auto font-mono text-[10px] text-content-subtle">⌘K</span>
      </button>

      <button
        type="button"
        aria-label="Notifications"
        class="relative p-2 rounded-md text-content-muted hover:text-content-strong hover:bg-surface-hover"
      >
        <.icon name="hero-bell" class="size-[17px]" />
        <span class="absolute top-1.5 right-1.5 size-1.5 rounded-full bg-accent" />
      </button>
      -->

      <.user_menu :if={@current_user} current_user={@current_user} />
      <.link :if={!@current_user} navigate={~p"/auth/oidcc"}>
        <.button variant={:secondary}>Sign In</.button>
      </.link>
    </header>
    """
  end

  attr(:crumbs, :list, required: true)

  defp crumbs(assigns) do
    ~H"""
    <nav :if={@crumbs != []} aria-label="Breadcrumb" class="min-w-0 flex items-center gap-1.5 text-sm">
      <ol class="flex items-center gap-1.5 min-w-0">
        <li :for={{crumb, idx} <- Enum.with_index(@crumbs)} class="flex items-center gap-1.5 min-w-0">
          <span :if={idx > 0} class="text-content-subtle" aria-hidden="true">/</span>
          <.link
            :if={crumb_path(crumb)}
            navigate={crumb_path(crumb)}
            class="text-content-muted hover:text-content-strong truncate"
          >
            {crumb_label(crumb)}
          </.link>
          <span :if={!crumb_path(crumb)} class="text-content-strong truncate" aria-current="page">
            {crumb_label(crumb)}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  attr(:nav_section, :atom, required: true)
  attr(:nav_items, :list, required: true)

  defp mobile_nav(assigns) do
    ~H"""
    <details
      id="mobile-nav-dropdown"
      class="mobile-nav-dropdown relative md:hidden"
      phx-click-away={JS.remove_attribute("open", to: "#mobile-nav-dropdown")}
    >
      <summary class="flex list-none cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-sm text-content hover:bg-surface-hover">
        <.icon name="hero-bars-3" class="size-4" />
        <span class="sr-only">Menu</span>
      </summary>
      <ul class="absolute left-0 top-full z-50 mt-2 w-56 rounded-lg border border-hairline bg-surface p-2 shadow-lg">
        <li :for={item <- @nav_items}>
          <.link
            navigate={nav_path(item.section)}
            class={[
              "block rounded-md px-3 py-2 text-sm",
              item.section == @nav_section && "text-content-strong bg-surface-active",
              item.section != @nav_section &&
                "text-content-muted hover:text-content-strong hover:bg-surface-hover"
            ]}
          >
            {item.label}
          </.link>
        </li>
      </ul>
    </details>
    """
  end

  attr(:current_user, :map, required: true)

  defp user_menu(assigns) do
    ~H"""
    <div class="relative">
      <.button
        variant={:icon}
        type="button"
        id="user-menu-button"
        aria-haspopup="menu"
        aria-expanded="false"
        class="h-8 w-8 rounded-full bg-surface-active border border-line text-[11px] text-content hover:border-line-strong"
        phx-click={JS.toggle(to: "#user-dropdown")}
        phx-click-away={
          JS.hide(
            to: "#user-dropdown",
            transition: {"ease-out duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
          )
        }
        phx-window-key="escape"
      >
        <span class="sr-only">Open user menu</span>
        <span aria-hidden="true">{user_initials(@current_user)}</span>
      </.button>
      <div
        id="user-dropdown"
        role="menu"
        aria-labelledby="user-menu-button"
        class="absolute right-0 mt-2 hidden z-[1000] w-56 rounded-md border border-hairline bg-surface shadow-lg"
      >
        <div class="px-4 py-3 border-b border-hairline">
          <p class="text-sm text-content-strong">Hello, {@current_user.name}!</p>
        </div>
        <ul class="py-1" aria-labelledby="user-menu-button">
          <li>
            <.link
              navigate={~p"/settings/access-tokens"}
              role="menuitem"
              class="block px-4 py-2 text-sm text-content-muted hover:bg-surface-hover hover:text-content-strong"
            >
              Access Tokens
            </.link>
          </li>
          <li>
            <.link
              navigate={~p"/settings"}
              role="menuitem"
              class="block px-4 py-2 text-sm text-content-muted hover:bg-surface-hover hover:text-content-strong"
            >
              Settings
            </.link>
          </li>
          <li>
            <a
              href="#"
              role="menuitem"
              class="block px-4 py-2 text-sm text-content-muted hover:bg-surface-hover hover:text-content-strong"
            >
              Sign out
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Shows login-specific authentication feedback.
  """
  attr(:flash, :map, required: true)
  attr(:id, :string, default: "auth-feedback")

  def auth_feedback(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, :auth_error)}
      id={@id}
      role="alert"
      data-auto-dismiss-ms="5000"
      class="mb-4 rounded-lg border border-danger/40 bg-danger-surface px-4 py-3 text-danger shadow-sm transition-opacity duration-300"
    >
      <p class="text-sm leading-5">{msg}</p>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  defp nav_path(:gardens), do: ~p"/gardens"
  defp nav_path(:seeds), do: ~p"/seeds"
  defp nav_path(:deployments), do: ~p"/deployments"
  defp nav_path(:forges), do: ~p"/forges"
  defp nav_path(:caches), do: ~p"/nix/caches"

  defp crumb_label({label, _path}), do: label
  defp crumb_label(label) when is_binary(label), do: label

  defp crumb_path({_label, path}), do: path
  defp crumb_path(_), do: nil

  defp resolve_crumbs([], nav_section), do: default_crumbs(nav_section)
  defp resolve_crumbs(crumbs, _nav_section), do: crumbs

  defp default_crumbs(:gardens), do: [{"Gardens", nil}]
  defp default_crumbs(:seeds), do: [{"Seeds", nil}]
  defp default_crumbs(:deployments), do: [{"Deployments", nil}]
  defp default_crumbs(:forges), do: [{"Forges", nil}]
  defp default_crumbs(:caches), do: [{"Nix caches", nil}]
  defp default_crumbs(_), do: []

  defp user_initials(%{name: name}) when is_binary(name) and name != "" do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp user_initials(_), do: "·"

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")
end
