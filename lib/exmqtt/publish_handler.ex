defmodule ExMQTT.PublishHandler do
  @moduledoc """
  Publish Handler behaviour for the MQTT client.
  """
  @callback handle_publish(message :: term, term) :: :ok
end
