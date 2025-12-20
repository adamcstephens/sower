alias Sower.Repo.Seeds.Preseed
require Logger

args = System.argv()

if length(args) < 1 do
  Logger.error("Missing user email")
  Kernel.exit(1)
end

email = args |> List.first()

Preseed.for_dev(email)
