defmodule Sower.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Sower.Accounts` context.
  """

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      name: "John Doe",
      oidc_id: UUIDv7.generate(),
      org_id: organization_fixture(%{name: "John Doe Organization"}).org_id
    })
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Sower.Accounts.User.new()

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def access_token_fixture(attrs \\ %{}) do
    {:ok, access_token, _token} =
      attrs
      |> Enum.into(%{"description" => "sample", "user_id" => user_fixture().id})
      |> Sower.Accounts.AccessToken.create()

    access_token
  end

  def organization_fixture(attrs \\ %{}) do
    {:ok, org} = attrs |> Enum.into(%{name: "test org"}) |> Sower.Accounts.Organization.create()

    org
  end
end
