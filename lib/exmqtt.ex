defmodule ExMQTT do
  @moduledoc """
  Documentation for MQTT client.
  """
  use GenServer

  require Logger

  defmodule State do
    defstruct [:conn_pid, :username, :client_id, :handler, :protocol_version, :subscriptions]
  end

  @type handler_functions :: %{
          :puback => function(),
          :publish => (:emqx_types.message() -> any()),
          :disconnected => ({reason_code :: 0..0xFF, properties :: term()} -> any())
        }

  @type opts :: [
          {:name, atom}
          | {:owner, pid}
          | {:handler_module, module}
          | {:handler_functions, handler_functions}
          | {:host, binary}
          | {:hosts, [{binary, :inet.port_number()}]}
          | {:port, :inet.port_number()}
          | {:tcp_opts, [:gen_tcp.option()]}
          | {:ssl, boolean}
          | {:ssl_opts, [:ssl.ssl_option()]}
          | {:ws_path, binary}
          | {:connect_timeout, pos_integer}
          | {:bridge_mode, boolean}
          | {:client_id, iodata}
          | {:clean_start, boolean}
          | {:username, iodata}
          | {:password, iodata}
          | {:protocol_version, 3 | 4 | 5}
          | {:keepalive, non_neg_integer}
          | {:max_inflight, pos_integer}
          | {:retry_interval, timeout}
          | {:will_topic, iodata}
          | {:will_payload, iodata}
          | {:will_retain, boolean}
          | {:will_qos, pos_integer}
          | {:will_props, %{atom => term}}
          | {:auto_ack, boolean}
          | {:ack_timeout, pos_integer}
          | {:force_ping, boolean}
          | {:properties, %{atom => term}}
          | {:subscriptions, [{topic :: binary, qos :: non_neg_integer}]}
          | {:start_when, {mfa, retry_in :: non_neg_integer}}
        ]

  @doc """
  Start the MQTT Client GenServer.
  """
  @spec start_link(opts) :: {:ok, pid}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Async

  def publish(message, topic, qos) do
    GenServer.cast(__MODULE__, {:publish, message, topic, qos})
  end

  def subscribe(topic, qos) do
    GenServer.cast(__MODULE__, {:subscribe, topic, qos})
  end

  def unsubscribe(topic) do
    GenServer.cast(__MODULE__, {:unsubscribe, topic})
  end

  def disconnect do
    GenServer.cast(__MODULE__, :disconnect)
  end

  ## Sync

  def publish_sync(message, topic, qos) do
    GenServer.call(__MODULE__, {:publish, message, topic, qos})
  end

  def subscribe_sync(topic, qos) do
    GenServer.call(__MODULE__, {:subscribe, topic, qos})
  end

  def unsubscribe_sync(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic})
  end

  def disconnect_sync do
    GenServer.call(__MODULE__, :disconnect)
  end

  # ----------------------------------------------------------------------------
  # Callbacks
  # ----------------------------------------------------------------------------

  ## Init

  def init(opts) do
    {start_when, opts} = Keyword.pop(opts, :start_when, :now)
    {subscriptions, opts} = Keyword.pop(opts, :subscriptions, [])

    # Assuming for now that if you provide handler functions, that you don't
    # also provide a handler module.
    {handler, opts} =
      if Keyword.has_key?(opts, :handler_functions) do
        {nil, opts}
      else
        Keyword.pop(opts, :handler_module, MQTT.Handler)
      end

    state = %State{
      username: opts[:username],
      client_id: opts[:client_id],
      protocol_version: opts[:protocol_version],
      handler: handler,
      subscriptions: subscriptions
    }

    {:ok, state, {:continue, {:start_when, start_when, opts}}}
  end

  ## Continue

  def handle_continue({:start_when, :now, opts}, state) do
    {:ok, state} = connect(opts, state)
    :ok = sub(state, state.subscriptions)
    {:noreply, state}
  end

  def handle_continue({:start_when, start_when, opts}, state) do
    {{module, function, args}, retry_in} = start_when

    if apply(module, function, args) do
      {:ok, state} = connect(opts, state)
      :ok = sub(state, state.subscriptions)
      {:noreply, state}
    else
      Process.sleep(retry_in)
      {:noreply, state, {:continue, {:start_when, start_when, opts}}}
    end
  end

  ## Call

  def handle_call({:publish, message, topic, qos}, _from, state) do
    pub(state, message, topic, qos)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, topic, qos}, _from, state) do
    sub(state, topic, qos)
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, topic}, _from, state) do
    unsub(state, topic)
    {:reply, :ok, state}
  end

  def handle_call(:disconnect, _from, state) do
    dc(state)
    {:reply, :ok, state}
  end

  ## Cast

  def handle_cast({:publish, message, topic, qos}, state) do
    pub(state, message, topic, qos)
    {:noreply, state}
  end

  def handle_cast({:subscribe, topic, qos}, state) do
    sub(state, topic, qos)
    {:noreply, state}
  end

  def handle_cast({:unsubscribe, topic}, state) do
    unsub(state, topic)
    {:noreply, state}
  end

  def handle_cast(:disconnect, state) do
    dc(state)
    {:noreply, state}
  end

  ## Info

  def handle_info({:publish, packet}, state) do
    %{payload: payload, topic: topic} = packet

    Logger.debug("[ExMQTT] Message received for #{topic}")

    if state.handler do
      :ok = apply(state.handler, :handle_message, [String.split(topic, "/"), payload])
    end

    {:noreply, state}
  end

  def handle_info({:disconnected, :shutdown, :ssl_closed}, state) do
    Logger.warn("[ExMQTT] Disconnected - shutdown, :ssl_closed")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn("[ExMQTT] Unhandled message #{inspect(msg)}")
    {:noreply, state}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp connect(opts, state) do
    Logger.debug("[ExMQTT] Connecting to #{opts[:host]}:#{opts[:port]}")

    opts = process_opts(opts)
    {:ok, conn_pid} = :emqtt.start_link(opts)
    {:ok, _props} = :emqtt.connect(conn_pid)
    {:ok, conn_pid}

    Logger.debug("[ExMQTT] Connected #{inspect(conn_pid)}")

    {:ok, %State{state | conn_pid: conn_pid}}
  end

  defp pub(state, message, topic, qos) do
    if qos == 0 do
      :ok = :emqtt.publish(state.conn_pid, topic, message, qos)
    else
      {:ok, _packet_id} = :emqtt.publish(state.conn_pid, topic, message, qos)
    end
  end

  defp sub(state, topics) when is_list(topics) do
    Enum.each(topics, fn {topic, qos} ->
      :ok = sub(state, topic, qos)
    end)
  end

  defp sub(state, topic, qos) do
    case :emqtt.subscribe(state.conn_pid, {topic, qos}) do
      {:ok, _props, [reason_code]} when reason_code in [0x00, 0x01, 0x02] ->
        Logger.debug("[ExMQTT] Subscribed to #{topic} @ QoS #{qos}")
        :ok

      {:ok, _props, reason_codes} ->
        Logger.error(
          "[ExMQTT] Subscription to #{topic} @ QoS #{qos} failed: #{inspect(reason_codes)}"
        )

        :error
    end
  end

  defp unsub(state, topic) do
    case :emqtt.unsubscribe(state.conn_pid, topic) do
      {:ok, _props, [0x00]} ->
        Logger.debug("[ExMQTT] Unsubscribed from #{topic}")
        :ok

      {:ok, _props, reason_codes} ->
        Logger.error("[ExMQTT] Unsubscribe from #{topic} failed #{inspect(reason_codes)}")
        :error
    end
  end

  defp dc(state) do
    :ok = :emqtt.disconnect(state.conn_pid)
  end

  ## Utility

  defp process_opts(opts) do
    opts
    |> validate_opts()
    |> map_opts()
  end

  defp validate_opts(opts) do
    # TODO!
    opts
  end

  # emqtt has some odd opt names and some erlang types that we'll want to
  # redefine but then map to emqtt expected format.
  defp map_opts(opts) do
    Enum.reduce(opts, [], &map_opt/2)
  end

  defp map_opt({:clean_session, val}, opts) do
    [{:clean_start, val} | opts]
  end

  defp map_opt({:client_id, val}, opts) do
    [{:clientid, val} | opts]
  end

  defp map_opt({:handler_functions, val}, opts) do
    [{:msg_handler, val} | opts]
  end

  defp map_opt({:host, val}, opts) do
    [{:host, to_charlist(val)} | opts]
  end

  defp map_opt({:hosts, hosts}, opts) do
    hosts = Enum.map(hosts, fn {host, port} -> {to_charlist(host), port} end)
    [{:hosts, hosts} | opts]
  end

  defp map_opt({:protocol_version, val}, opts) do
    version =
      case val do
        3 -> :v3
        4 -> :v4
        5 -> :v5
      end

    [{:proto_ver, version} | opts]
  end

  defp map_opt({:ws_path, val}, opts) do
    [{:ws_path, to_charlist(val)} | opts]
  end

  defp map_opt(opt, opts) do
    [opt | opts]
  end
end
