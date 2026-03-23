Application.ensure_all_started([:sower])
if Code.loaded?(Sower.Accounts.Organization) do
  Sower.Accounts.Organization.list()
  |> List.first()
  |> Map.get(:org_id)
  |> Sower.Repo.put_org_id()
else
  Application.ensure_all_started([:exsync])
end
IEx.configure(
  inspect: [
    pretty: true,
    limit: 1000,
    width: 80
  ],
  width: 80
)
