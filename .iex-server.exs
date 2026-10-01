Application.ensure_all_started([:sower])

if Code.loaded?(Sower.Accounts.Organization) do
  if organization = List.first(Sower.Accounts.Organization.list()) do
    Sower.Repo.put_org_id(organization.org_id)
  end
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
