Application.ensure_all_started([:erlexec, :exsync, :sower_agent])

IEx.configure(
  inspect: [
    pretty: true,
    limit: 1000,
    width: 80
  ],
  width: 80
)
