defmodule ExMQTT.Handler do
  @moduledoc """
  Handler behaviour for the MQTT client.
  """

  @callback handle_message(String.t(), String.t()) :: :ok

  require Logger

  def handle_message(_topic, _message) do
    Logger.warn("[ExMQTT] Message received but no handler module defined")
    :ok
  end
end
