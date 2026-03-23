Application.ensure_all_started([:exsync, :garden])

IEx.configure(
  inspect: [
    pretty: true,
    limit: 1000,
    width: 80
  ],
  width: 80
)
