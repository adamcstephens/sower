defmodule SowerAgent.Scheduler do
  use Quantum, otp_app: :sower_agent

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

        case find_job(job_name) do
          nil ->
            Logger.info(
              msg: "Creating new subscription scheduler",
              sub_sid: sid,
              schedule: schedule
            )

            new_job()
            |> Quantum.Job.set_name(job_name_sub(sid))

          job ->
            Logger.info(
              msg: "Found existing subscription scheduler, refreshing",
              sub_sid: sid,
              schedule: schedule
            )

            job
        end
        |> Quantum.Job.set_timezone(get_timezone())
        |> Quantum.Job.set_schedule(cron)
        |> Quantum.Job.set_task(fn ->
          subscriptions = SowerAgent.Storage.read().subscriptions || []

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

              SowerAgent.Client.deploy(subscription)
          end
        end)
        |> add_job()

        job_name

      {:error, error} ->
        Logger.error(
          msg: "Failed to parse schedule",
          error: error,
          schedule: schedule,
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
