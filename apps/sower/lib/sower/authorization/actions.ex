defmodule Sower.Authorization.Actions do
  use Permit.Actions

  @impl Permit.Actions
  def grouping_schema do
    crud_grouping()
    |> Map.merge(%{
      submit: []
    })
  end
end
