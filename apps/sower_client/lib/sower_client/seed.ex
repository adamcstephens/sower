defmodule SowerClient.Seed do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "get:seed"

  @seed_types ["nixos", "home-manager", "nix-darwin", "service"]

  OpenApiSpex.schema(%{
    title: "Seed",
    description: "A seed is an installable unit",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "sid of the seed set by the server",
        nullable: true,
        readOnly: true
      },
      name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: @seed_types
      },
      artifact: %Schema{
        type: :string,
        description: "Artifact of the seed"
      },
      tags: %Schema{
        type: :array,
        description: "Tags associated with the seed",
        items: SowerClient.SeedTag,
        default: []
      }
    },
    required: [:name, :seed_type, :artifact],
    example: %{
      "sid" => "example4ser3adju75ddusbr",
      "name" => "myhost",
      "seed_type" => "nixos",
      "artifact" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos",
      "tags" => []
    }
  })

  def seed_types() do
    @seed_types
  end

  defguard is_seed_type?(s) when s in @seed_types

  def get(sid) when is_binary(sid) do
    get(SowerClient.ApiClient.new(), sid)
  end

  def get(%Req.Request{} = req, sid) do
    case Req.get(req, url: "/seeds/:sid", path_params: [sid: sid]) do
      {:ok, %{status: 200, body: body}} ->
        __MODULE__.cast(body)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end

  def latest(name, seed_type) when is_seed_type?(seed_type) do
    latest(SowerClient.ApiClient.new(), name, seed_type)
  end

  def latest(%Req.Request{} = req, name, seed_type) when is_seed_type?(seed_type) do
    case Req.get(req,
           url: "/seeds/latest",
           params: [name: name, seed_type: seed_type]
         ) do
      {:ok, %{status: 200, body: body}} ->
        __MODULE__.cast(body)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end

  def latest(name, seed_type, tags) when is_seed_type?(seed_type) and is_list(tags) do
    latest(SowerClient.ApiClient.new(), name, seed_type, tags)
  end

  def latest(%Req.Request{} = req, name, seed_type, tags)
      when is_seed_type?(seed_type) and is_list(tags) do
    tag_params = Enum.map(tags, &{:"tags[]", SowerClient.SeedTag.to_query_string(&1)})
    params = [name: name, seed_type: seed_type] ++ tag_params

    case Req.get(req,
           url: "/seeds/latest",
           params: params
         ) do
      {:ok, %{status: 200, body: body}} ->
        __MODULE__.cast(body)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end

  def list(name, seed_type) when is_seed_type?(seed_type) do
    list(SowerClient.ApiClient.new(), name, seed_type)
  end

  def list(%Req.Request{} = req, name, seed_type) when is_seed_type?(seed_type) do
    case Req.get(req,
           url: "/seeds",
           params: [name: name, seed_type: seed_type]
         ) do
      {:ok, %{status: 200, body: body}} ->
        Enum.map(body, &__MODULE__.cast!/1)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end

  def create(%__MODULE__{} = seed) do
    create(SowerClient.ApiClient.new(), seed)
  end

  def create(%{} = seed) do
    case __MODULE__.cast(seed) do
      {:ok, seed} -> create(seed)
      error -> error
    end
  end

  def create(%Req.Request{} = req, %__MODULE__{} = seed) do
    case Req.post(req,
           url: "/seeds",
           json: seed
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        __MODULE__.cast(body)

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, _} = err ->
        err
    end
  end
end
