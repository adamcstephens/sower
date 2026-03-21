defmodule SowerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SowerWeb, :html

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header>
      <nav class="bg-zinc-200 dark:bg-zinc-800 w-full">
        <div class="mx-auto flex max-w-screen-xl items-center justify-between p-4">
          <div class="md:order-1">
            <details class="mobile-nav-dropdown relative md:hidden">
              <summary class="flex list-none cursor-pointer items-center gap-2 rounded-lg bg-zinc-100 px-3 py-2 text-sm font-semibold text-zinc-900 hover:bg-zinc-300/80 dark:bg-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-600 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-500 dark:focus-visible:ring-zinc-300">
                Menu
                <svg
                  class="mobile-nav-dropdown-chevron size-4 stroke-zinc-900 dark:stroke-zinc-200"
                  viewBox="0 0 24 24"
                  fill="none"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    d="M6 9L12 15L18 9"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              </summary>
              <ul class="mobile-nav-dropdown-panel absolute left-0 top-full z-50 mt-2 w-56 rounded-lg border border-zinc-300 bg-zinc-100 p-2 shadow-lg dark:border-zinc-600 dark:bg-zinc-700">
                <li>
                  <.link
                    navigate={~p"/gardens"}
                    class="block rounded-md px-3 py-2 hover:text-orange-700 hover:bg-zinc-200 dark:hover:text-orange-300 dark:hover:bg-zinc-600"
                  >
                    Gardens
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/seeds"}
                    class="block rounded-md px-3 py-2 hover:text-orange-700 hover:bg-zinc-200 dark:hover:text-orange-300 dark:hover:bg-zinc-600"
                  >
                    Seeds
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/deployments"}
                    class="block rounded-md px-3 py-2 hover:text-orange-700 hover:bg-zinc-200 dark:hover:text-orange-300 dark:hover:bg-zinc-600"
                  >
                    Deployments
                  </.link>
                </li>
              </ul>
            </details>

            <ul class="hidden font-medium md:flex md:items-center md:space-x-8 rtl:space-x-reverse">
              <li>
                <.link
                  navigate={~p"/gardens"}
                  class="hover:text-orange-700 dark:hover:text-orange-300"
                >
                  Gardens
                </.link>
              </li>
              <li>
                <.link navigate={~p"/seeds"} class="hover:text-orange-700 dark:hover:text-orange-300">
                  Seeds
                </.link>
              </li>
              <%!-- <li> --%>
              <%!--   <.link --%>
              <%!--     navigate={~p"/nix/caches"} --%>
              <%!--     class="hover:text-orange-700 dark:hover:text-orange-300" --%>
              <%!--   > --%>
              <%!--     Caches --%>
              <%!--   </.link> --%>
              <%!-- </li> --%>
              <%!-- <li> --%>
              <%!--   <.link navigate={~p"/forges"} class="hover:text-orange-700 dark:hover:text-orange-300"> --%>
              <%!--     Forges --%>
              <%!--   </.link> --%>
              <%!-- </li> --%>
              <li>
                <.link
                  navigate={~p"/deployments"}
                  class="hover:text-orange-700 dark:hover:text-orange-300"
                >
                  Deployments
                </.link>
              </li>
            </ul>
          </div>

          <div class="relative flex shrink-0 items-center md:order-2 md:space-x-0 rtl:space-x-reverse">
            <%= if @current_user || nil do %>
              <.button
                variant={:icon}
                type="button"
                class="flex text-sm bg-zinc-800 rounded-full md:me-0 focus:ring-4 focus:ring-zinc-300 dark:focus:ring-zinc-600"
                id="user-menu-button"
                aria-expanded="false"
                data-dropdown-toggle="user-dropdown"
                data-dropdown-placement="bottom"
                phx-click={JS.toggle(to: "#user-dropdown")}
                phx-click-away={
                  JS.hide(
                    to: "#user-dropdown",
                    transition:
                      {"ease-out duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
                  )
                }
                phx-key="escape"
                phx-window-key={
                  JS.hide(
                    to: "#user-dropdown",
                    transition:
                      {"ease-out duration-75", "opacity-100 scale-100", "opacity-0 scale-95"}
                  )
                }
              >
                <span class="sr-only">Open user menu</span>
                <svg
                  width="24px"
                  height="24px"
                  stroke-width="0.5"
                  viewBox="0 0 24 24"
                  xmlns="http://www.w3.org/2000/svg"
                  class="stroke-zinc-900 dark:stroke-zinc-200 fill-zinc-200 dark:fill-zinc-800 hover:fill-orange-300 dark:hover:fill-orange-700"
                >
                  <path
                    d="M12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2Z"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                  </path>
                  <path
                    d="M4.271 18.3457C4.271 18.3457 6.50002 15.5 12 15.5C17.5 15.5 19.7291 18.3457 19.7291 18.3457"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                  </path>
                  <path
                    d="M12 12C13.6569 12 15 10.6569 15 9C15 7.34315 13.6569 6 12 6C10.3431 6 9 7.34315 9 9C9 10.6569 10.3431 12 12 12Z"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                  </path>
                </svg>
              </.button>
              <div
                class="absolute z-[1000] m-0 hidden top-8 right-8 whitespace-nowrap text-base list-none bg-white divide-y divide-zinc-100 rounded-lg shadow dark:bg-zinc-700 dark:divide-zinc-600"
                id="user-dropdown"
              >
                <div class="px-4 py-3">
                  <span class="px-3 py-2 text-sm font-medium text-zinc-700 dark:text-zinc-200 rounded-md">
                    Hello, {@current_user.name}!
                  </span>
                </div>
                <ul class="py-2" aria-labelledby="user-menu-button">
                  <li>
                    <.link
                      navigate={~p"/settings/access-tokens"}
                      class="block px-4 py-2 text-sm text-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-600 dark:text-zinc-200 dark:hover:text-white"
                    >
                      Access Tokens
                    </.link>
                  </li>
                  <li>
                    <.link
                      navigate={~p"/settings"}
                      class="block px-4 py-2 text-sm text-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-600 dark:text-zinc-200 dark:hover:text-white"
                    >
                      Settings
                    </.link>
                  </li>
                  <li>
                    <a
                      href="#"
                      class="block px-4 py-2 text-sm text-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-600 dark:text-zinc-200 dark:hover:text-white"
                    >
                      Sign out
                    </a>
                  </li>
                </ul>
              </div>
            <% else %>
              <.link navigate={~p"/auth/oidcc"}>
                <.button variant={:secondary}>Sign In</.button>
              </.link>
            <% end %>
          </div>
        </div>
      </nav>
    </header>
    <main class="px-4 py-8 sm:px-6 lg:px-8 relative">
      <div class="mx-auto max-w-screen-xl">
        <.auth_feedback flash={@flash} />
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  @doc """
  Shows login-specific authentication feedback.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "auth-feedback"

  def auth_feedback(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, :auth_error)}
      id={@id}
      role="alert"
      data-auto-dismiss-ms="5000"
      class="mb-4 rounded-lg border border-rose-200 bg-rose-50 px-4 py-3 text-rose-900 shadow-sm transition-opacity duration-300"
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
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <.button
        variant={:icon}
        class="flex p-2 w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </.button>

      <.button
        variant={:icon}
        class="flex p-2 w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </.button>

      <.button
        variant={:icon}
        class="flex p-2 w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </.button>
    </div>
    """
  end

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"
end
