defmodule Flume.PipelineStatsTest do
  use TestWithRedis
  use TestWithEts

  alias Flume.{PipelineStats}
  @redis_namespace Flume.Config.get(:namespace)

  describe "persist/0" do
    test "persist pipeline stats to Redis" do
      pipeline_name = "test_pipeline"

      PipelineStats.register(pipeline_name)

      command =
        ~w(MGET #{@redis_namespace}:stat:processed:#{pipeline_name} #{@redis_namespace}:stat:failed:#{
          pipeline_name
        })

      assert {:ok, [nil, nil]} == Flume.Redis.Client.query(command)

      PipelineStats.incr(:processed, pipeline_name)
      PipelineStats.incr(:processed, pipeline_name)
      PipelineStats.incr(:failed, pipeline_name)

      PipelineStats.persist()
      assert {:ok, ["2", "1"]} == Flume.Redis.Client.query(command)
    end
  end
end
