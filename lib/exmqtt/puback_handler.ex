defmodule ExMQTT.PubAckHandler do
  @moduledoc """
  PubAck Handler behaviour for the MQTT client.
  """
  @callback handle_puback(ack :: term, term) :: :ok
end
