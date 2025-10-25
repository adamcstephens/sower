Sower.Accounts.Organization.list() |> List.first() |> Map.get(:org_id) |> Sower.Repo.put_org_id()
