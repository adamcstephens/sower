defmodule SowerWeb.ManagedProfilesComponentTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  alias Sower.Orchestration.ManagedProfile

  alias SowerClient.Orchestration.{
    GardenSeedGeneration,
    GardenSeedProfile,
    ProfileOperationResult
  }

  setup [:register_and_log_in_user]

  setup %{user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture(%{capabilities: ["managed_profiles_v1"]})

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        name: "tools",
        seed_name: "hello",
        seed_type: "package"
      })

    generation = %GardenSeedGeneration{
      generation_id: "retained-generation",
      generation_number: 2,
      path: "/nix/store/package",
      link: "/var/lib/sower-profiles/tools/profile-2-link",
      generation_path: "/var/lib/sower-profiles/tools/profile-2-link",
      created: DateTime.utc_now(),
      is_current: true,
      pinned: true,
      is_staged: false
    }

    profile = %GardenSeedProfile{
      name: "tools",
      subscription_sid: subscription.sid,
      seed_type: "package",
      managed: true,
      profile_path: "/var/lib/sower-profiles/tools/profile",
      lifecycle_status: "installed",
      generations: [generation]
    }

    :ok = ManagedProfile.observe(garden, [profile])
    %{garden: garden, subscription: subscription, profile: profile}
  end

  test "shows last observed paths, durable IDs, pins and omitted retention", %{
    conn: conn,
    garden: garden
  } do
    {:ok, view, html} = live(conn, ~p"/gardens/#{garden}")
    assert html =~ "Last reported Garden state"
    assert html =~ "/var/lib/sower-profiles/tools/profile-2-link"
    assert html =~ "retained-generation"
    assert html =~ "Pinned"
    assert html =~ "keep all generations"
    refute has_element?(view, "button", "Prune")
  end

  test "uninstall previews affected generations then remains pending offline", %{
    conn: conn,
    garden: garden,
    subscription: subscription
  } do
    {:ok, view, _} = live(conn, ~p"/gardens/#{garden}")
    view |> element("#profile-tools button", "Preview uninstall") |> render_click()
    assert has_element?(view, "#garden-managed-profiles-result", "preview")
    assert render(view) =~ "Affected generation: retained-generation"
    assert render(view) =~ "External services are not stopped"

    view
    |> element("#garden-managed-profiles-result button", "Confirm uninstall")
    |> render_click()

    assert has_element?(view, "#garden-managed-profiles-result", "pending")
    assert Sower.Repo.reload!(subscription).uninstall_pending
  end

  test "generation controls preserve explicit destination and opaque ID", %{
    conn: conn,
    garden: garden
  } do
    Phoenix.PubSub.subscribe(Sower.PubSub, "managed_profile_dispatch:#{garden.sid}")
    {:ok, view, _} = live(conn, ~p"/gardens/#{garden}")
    view |> element("#profile-tools button[phx-value-action=unpin]") |> render_click()
    assert_receive {:profile_operation, operation}
    assert operation.profile_name == "tools"
    assert operation.generation_id == "retained-generation"
    assert operation.action == "unpin"

    {:ok, _} =
      ManagedProfile.acknowledge(garden, %ProfileOperationResult{
        request_id: operation.request_id,
        status: "blocked",
        error: "operation in flight"
      })

    view |> element("#garden-managed-profiles button", "Refresh observation") |> render_click()
    assert has_element?(view, "#garden-managed-profiles-result", "blocked")
    assert render(view) =~ "operation in flight"
  end

  test "subscription retention form saves numeric limits and can retain all", %{
    conn: conn,
    garden: garden,
    subscription: subscription
  } do
    {:ok, view, _} = live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}/edit")

    view
    |> form("#subscription-form",
      subscription: %{
        retention_enabled: "true",
        retention: %{keep_generations: "3", keep_days: "30"}
      }
    )
    |> render_submit()

    assert Sower.Repo.reload!(subscription).retention == %{
             "keep_generations" => 3,
             "keep_days" => 30
           }

    {:ok, view, _} = live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}/edit")

    view
    |> form("#subscription-form", subscription: %{retention_enabled: "false"})
    |> render_submit()

    assert is_nil(Sower.Repo.reload!(subscription).retention)
  end

  test "declared subscriptions explain retention override ownership", %{
    conn: conn,
    garden: garden,
    subscription: subscription
  } do
    subscription
    |> Ecto.Changeset.change(origin: "declared")
    |> Sower.Repo.update!()

    {:ok, view, html} = live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}/edit")
    assert html =~ "declared"
    assert has_element?(view, "#subscription-form", "remains effective until the declared")
    refute has_element?(view, "input[name='subscription[origin]']")
  end

  test "operator creation reports declared name conflicts without takeover", %{
    conn: conn,
    garden: garden,
    subscription: subscription
  } do
    subscription |> Ecto.Changeset.change(origin: "declared") |> Sower.Repo.update!()
    {:ok, view, _} = live(conn, ~p"/gardens/#{garden}/subscriptions/new")

    view
    |> form("#subscription-form",
      subscription: %{name: "tools", seed_name: "hello", seed_type: "package"}
    )
    |> render_submit()

    assert render(view) =~ "cannot be taken over"
    assert Sower.Repo.reload!(subscription).origin == "declared"
  end

  test "operator creation reports pending removal instead of recreating", %{
    conn: conn,
    garden: garden,
    subscription: subscription
  } do
    subscription |> Ecto.Changeset.change(uninstall_pending: true) |> Sower.Repo.update!()
    {:ok, view, _} = live(conn, ~p"/gardens/#{garden}/subscriptions/new")

    view
    |> form("#subscription-form",
      subscription: %{name: "tools", seed_name: "hello", seed_type: "package"}
    )
    |> render_submit()

    assert render(view) =~ "pending uninstall"
    assert Sower.Repo.reload!(subscription).uninstall_pending
  end
end
