defmodule Garden.Scheduler do
  use Quantum, otp_app: :garden

  require Logger

  @sub_prefix "subsched_"

  def refresh_subscriptions(subscriptions) do
    existing_jobs =
      jobs()
      |> Keyword.keys()
      |> Enum.filter(fn name -> name |> to_string() |> String.starts_with?(@sub_prefix) end)

    new_jobs = Enum.map(subscriptions, &add_subscription_schedule/1)

    # clean up any stale jobs
    (existing_jobs -- new_jobs)
    |> Enum.map(&clean_sub_schedule/1)

    new_jobs
  end

  def add_subscription_schedule(%SowerClient.Orchestration.Subscription{
        sid: sid,
        schedule: schedule
      })
      when not is_nil(sid) and not is_nil(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, cron} ->
        job_name = job_name_sub(sid)

        job =
          case find_job(job_name) do
            nil ->
              new_job()
              |> Quantum.Job.set_name(job_name_sub(sid))

            job ->
              job
          end

        job
        |> Quantum.Job.set_timezone(get_timezone())
        |> Quantum.Job.set_schedule(cron)
        |> Quantum.Job.set_overlap(false)
        |> Quantum.Job.set_task(fn ->
          deploy_if_not_cooled_down(sid, schedule)
        end)
        |> add_job()

        # re-fetch the job since add_job is async
        job = find_job(job_name)

        tz =
          case job.timezone do
            :utc -> "Etc/UTC"
            tz when is_binary(tz) -> tz
          end

        next_run =
          job.schedule
          |> Crontab.Scheduler.get_next_run_date!(DateTime.now!(tz))
          |> DateTime.to_iso8601()

        Logger.info(
          msg: "Setup subscription schedule",
          sub_sid: sid,
          schedule: schedule,
          job: job.name,
          schedule: job.schedule,
          next_run: next_run
        )

        job.name

      {:error, error} ->
        Logger.error(
          msg: "Failed to parse schedule",
          error: error,
          subscription_sid: sid
        )

        nil
    end
  end

  def add_subscription_schedule(%SowerClient.Orchestration.Subscription{
        sid: sid,
        schedule: nil
      }) do
    Logger.info(
      msg: "Subscription has no schedule, skipping schedule start",
      subscription_sid: sid
    )

    nil
  end

  def clean_sub_schedule(name) do
    Logger.info(msg: "Deleting stale job", job: to_string(name))

    delete_job(name)
  end

  defp job_name_sub(sid) do
    :"#{@sub_prefix}#{sid}"
  end

  def deploy_if_not_cooled_down(sid, schedule, opts \\ []) do
    deploy_fun = Keyword.get(opts, :deploy_fun, &Garden.Socket.deploy/1)
    check_cooldown = Keyword.get(opts, :check_cooldown, &Garden.Storage.check_cooldown/1)

    read_subscriptions =
      Keyword.get(opts, :read_subscriptions, fn ->
        Garden.Storage.read().subscriptions || []
      end)

    case check_cooldown.({:schedule, sid}) do
      {:cooldown, seconds_ago} ->
        Logger.info(
          msg: "Skipping scheduled deployment, fired recently",
          subscription_sid: sid,
          schedule: schedule,
          seconds_since_last: seconds_ago
        )

        :skipped

      :ok ->
        subscriptions = read_subscriptions.()

        case Enum.find(subscriptions, &(&1.sid == sid)) do
          nil ->
            Logger.warning(
              msg: "Subscription not found for scheduled deployment",
              subscription_sid: sid
            )

          subscription ->
            Logger.info(
              msg: "Running scheduled deployment",
              subscription_sid: sid,
              schedule: schedule
            )

            deploy_fun.(subscription)
        end
    end
  end

  def get_timezone() do
    with timedatectl when not is_nil(timedatectl) <- System.find_executable("timedatectl"),
         {tz, 0} <- System.cmd(timedatectl, ["show", "--property=Timezone", "--value"]) do
      String.trim(tz)
    else
      {error, 1} ->
        Logger.error(
          msg: "Failed to run timedatectl to get tz, falling back to UTC",
          error: error
        )

        :utc
    end
  end
end
