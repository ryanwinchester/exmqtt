defmodule ExMQTT.DisconnectHandler do
  @moduledoc """
  Disconnect Handler behaviour for the MQTT client.
  """
  @callback handle_disconnect({reason_code :: 0..0xFF, properties :: term}, term) :: :ok
end
