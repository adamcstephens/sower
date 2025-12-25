if Application.started_applications() |> Enum.find(&(elem(&1, 0) == :ecto)) do
  Sower.Accounts.Organization.list()
  |> List.first()
  |> Map.get(:org_id)
  |> Sower.Repo.put_org_id()
else
  Application.ensure_all_started([:erlexec, :exsync])
end

IEx.configure(
  inspect: [
    pretty: true,
    limit: 1000,
    width: 80
  ],
  width: 80
)
