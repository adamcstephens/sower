defmodule CircusClient do
  defmodule Project do
    use TypedStruct

    typedstruct do
      field :id, String.t(), enforce: true
      field :name, String.t(), enforce: true
      field :repository_url, String.t(), enforce: true
    end
  end

  defmodule ProjectPage do
    use TypedStruct

    typedstruct do
      field :items, [Project.t()], enforce: true
      field :total, non_neg_integer(), enforce: true
      field :limit, pos_integer(), enforce: true
      field :offset, non_neg_integer(), enforce: true
    end
  end

  def new do
    config = Application.fetch_env!(:sower, __MODULE__)

    Req.new(
      base_url: String.trim_trailing(Keyword.fetch!(config, :url), "/") <> "/api/v1",
      auth: {:bearer, Keyword.fetch!(config, :api_key)},
      retry: false
    )
  end

  def list_projects(request \\ new()) do
    case Req.get(request, url: "/projects") do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"items" => items, "total" => total, "limit" => limit, "offset" => offset}
       }} ->
        {:ok,
         %ProjectPage{
           items:
             Enum.map(items, fn project ->
               %Project{
                 id: Map.fetch!(project, "id"),
                 name: Map.fetch!(project, "name"),
                 repository_url: Map.fetch!(project, "repository_url")
               }
             end),
           total: total,
           limit: limit,
           offset: offset
         }}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
