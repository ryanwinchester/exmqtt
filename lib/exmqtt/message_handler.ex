defmodule ExMQTT.MessageHandler do
  @moduledoc """
  Message Handler behaviour for the MQTT client.
  """
  @callback handle_message(topic :: String.t(), message :: String.t(), term) :: :ok
end
