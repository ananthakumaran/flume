defmodule Flume.Redis.Job do
  require Flume.Logger

  alias Flume.Logger
  alias Flume.Support.Time
  alias Flume.Redis.{Client, Script, SortedSet}

  @rpop_lpush_zadd_sha Script.sha(:rpop_lpush_zadd)
  @rpop_lpush_zadd_limited_sha Script.sha(:rpop_lpush_zadd_limited)

  @enqueue_backup_jobs_sha Script.sha(:enqueue_backup_jobs)
  @enqueue_backup_jobs_old_sha Script.sha(:enqueue_backup_jobs_old)

  def enqueue(queue_key, job) do
    try do
      response = Client.lpush(queue_key, job)

      case response do
        {:ok, [%Redix.Error{}, %Redix.Error{}]} = error -> error
        {:ok, [%Redix.Error{}, _]} = error -> error
        {:ok, [_, %Redix.Error{}]} = error -> error
        {:ok, [_, _]} -> :ok
        other -> other
      end
    catch
      :exit, e ->
        Logger.info("Error enqueueing -  #{Kernel.inspect(e)}")
        {:error, :timeout}
    end
  end

  def bulk_enqueue(queue_key, jobs) do
    commands =
      Enum.map(jobs, fn job ->
        Client.lpush_command(queue_key, job)
      end)

    case Client.pipeline(commands) do
      {:error, reason} ->
        {:error, reason}

      {:ok, reponses} ->
        updated_responses =
          reponses
          |> Enum.map(fn response ->
            case response do
              value when value in [:undefined, nil] ->
                nil

              error when error in [%Redix.Error{}, %Redix.ConnectionError{}] ->
                Logger.error("Error running command - #{Kernel.inspect(error)}")
                nil

              value ->
                value
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, updated_responses}
    end
  end

  def bulk_dequeue(dequeue_key, enqueue_key, processing_sorted_set_key, count, current_score) do
    Client.evalsha_command([
      @rpop_lpush_zadd_sha,
      _num_of_keys = 3,
      dequeue_key,
      enqueue_key,
      processing_sorted_set_key,
      count,
      current_score
    ])
    |> do_bulk_dequeue()
  end

  def bulk_dequeue(
        dequeue_key,
        enqueue_key,
        processing_sorted_set_key,
        limit_sorted_set_key,
        count,
        max_count,
        previous_score,
        current_score
      ) do
    Client.evalsha_command([
      @rpop_lpush_zadd_limited_sha,
      _num_of_keys = 4,
      dequeue_key,
      enqueue_key,
      processing_sorted_set_key,
      limit_sorted_set_key,
      count,
      max_count,
      previous_score,
      current_score
    ])
    |> do_bulk_dequeue()
  end

  defp do_bulk_dequeue(command) do
    case Client.query(command) do
      {:error, reason} ->
        {:error, reason}

      {:ok, reponses} ->
        success_responses =
          reponses
          |> Enum.map(fn response ->
            case response do
              value when value in [:undefined, nil] ->
                nil

              error when error in [%Redix.Error{}, %Redix.ConnectionError{}] ->
                Logger.error("#{__MODULE__} - Error running command - #{Kernel.inspect(error)}")
                nil

              value ->
                value
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, success_responses}
    end
  end

  # TODO - Deprecated, remove this later!
  def enqueue_backup_jobs_old(sorted_set_key, namespace, score, enqueued_at) do
    Client.evalsha_command([
      @enqueue_backup_jobs_old_sha,
      _num_of_keys = 1,
      sorted_set_key,
      namespace,
      score,
      enqueued_at
    ])
    |> Client.query()
    |> case do
      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        {:ok, response}
    end
  end

  def enqueue_backup_jobs(sorted_set_key, queue_key, backup_key, current_score) do
    Client.evalsha_command([
      @enqueue_backup_jobs_sha,
      _num_of_keys = 3,
      sorted_set_key,
      queue_key,
      backup_key,
      current_score
    ])
    |> Client.query()
    |> case do
      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        {:ok, response}
    end
  end

  def bulk_enqueue_scheduled!(queues_and_jobs) do
    bulk_enqueue_commands(queues_and_jobs)
    |> Client.pipeline()
    |> case do
      {:error, reason} ->
        [{:error, reason}]

      {:ok, responses} ->
        queues_and_jobs
        |> Enum.zip(responses)
        |> Enum.map(fn {{scheduled_queue, _, job}, response} ->
          case response do
            value when value in [:undefined, nil] ->
              nil

            error when error in [%Redix.Error{}, %Redix.ConnectionError{}] ->
              Logger.error("Error running command - #{Kernel.inspect(error)}")
              nil

            _value ->
              {scheduled_queue, job}
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  def bulk_remove_scheduled!(scheduled_queues_and_jobs) do
    bulk_remove_scheduled_commands(scheduled_queues_and_jobs)
    |> Client.pipeline()
    |> case do
      {:error, reason} ->
        [{:error, reason}]

      {:ok, responses} ->
        scheduled_queues_and_jobs
        |> Enum.zip(responses)
        |> Enum.map(fn {{_, job}, response} ->
          case response do
            value when value in [:undefined, nil] ->
              nil

            error when error in [%Redix.Error{}, %Redix.ConnectionError{}] ->
              Logger.error("Error running command - #{Kernel.inspect(error)}")
              nil

            _value ->
              job
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  def schedule_job(queue_key, schedule_at, job) do
    score =
      if is_float(schedule_at) do
        schedule_at |> Float.to_string()
      else
        schedule_at |> Integer.to_string()
      end

    try do
      case SortedSet.add(queue_key, score, job) do
        {:ok, jid} -> {:ok, jid}
        other -> other
      end
    catch
      :exit, e ->
        Logger.info("Error enqueueing -  #{Kernel.inspect(e)}")
        {:error, :timeout}
    end
  end

  def remove_job!(queue_key, job) do
    Client.lrem!(queue_key, job)
  end

  def remove_scheduled_job!(queue_key, job) do
    SortedSet.remove!(queue_key, job)
  end

  def fail_job!(queue_key, job) do
    SortedSet.add!(queue_key, Time.time_to_score(), job)
  end

  def fetch_all!(queue_key) do
    Client.lrange!(queue_key)
  end

  def fetch_all!(:retry, queue_key) do
    SortedSet.fetch_by_range!(queue_key)
  end

  def scheduled_jobs(queues, score) do
    Enum.map(queues, &["ZRANGEBYSCORE", &1, 0, score])
    |> Client.pipeline()
    |> case do
      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        updated_jobs =
          response
          |> Enum.map(fn jobs ->
            Enum.map(jobs, fn job ->
              case job do
                value when value in [:undefined, nil] ->
                  nil

                error when error in [%Redix.Error{}, %Redix.ConnectionError{}] ->
                  Logger.error("Error running command - #{Kernel.inspect(error)}")
                  nil

                value ->
                  value
              end
            end)
            |> Enum.reject(&is_nil/1)
          end)

        {:ok, Enum.zip(queues, updated_jobs)}
    end
  end

  defp bulk_enqueue_commands([]), do: []

  defp bulk_enqueue_commands([{_, queue_name, job} | queues_and_jobs]) do
    cmd = ["LPUSH", queue_name, job]
    [cmd | bulk_enqueue_commands(queues_and_jobs)]
  end

  defp bulk_remove_scheduled_commands([]), do: []

  defp bulk_remove_scheduled_commands([{set_name, job} | scheduled_queues_and_jobs]) do
    cmd = ["ZREM", set_name, job]
    [cmd | bulk_remove_scheduled_commands(scheduled_queues_and_jobs)]
  end
end
