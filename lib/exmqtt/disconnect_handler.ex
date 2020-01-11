defmodule ExMQTT.DisconnectHandler do
  @moduledoc """
  Disconnect Handler behaviour for the MQTT client.
  """

  @callback handle_disconnect({reason_code :: 0..0xFF, properties :: term}) :: :ok

  require Logger

  def handle_disconnect(_reason_code, _properties) do
    Logger.warn("[ExMQTT] Disconnect received but no handler module defined")
    :ok
  end
end
