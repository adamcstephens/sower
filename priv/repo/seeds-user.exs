alias Sower.Repo.Seeds.Org
require Logger

args = System.argv() |> dbg()

if length(args) < 1 do
  Logger.error("Missing user email")
  Kernel.exit(1)
end

email = args |> List.first()
name = email |> String.split("@") |> List.first()

Org.new(%Org{name: name, email: email})
