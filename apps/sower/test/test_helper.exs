Application.put_env(:sower, :public_url, "http://localhost:4000")

ExUnit.start()
Faker.start()
Ecto.Adapters.SQL.Sandbox.mode(Sower.Repo, :manual)
