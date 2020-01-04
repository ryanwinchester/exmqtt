defmodule ExMQTT.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(opts) do
    {supervision_opts, opts} = Keyword.pop(opts, :supervision, strategy: :one_for_one)

    children = [{ExMQTT, opts}]

    Supervisor.init(children, supervision_opts)
  end
end
