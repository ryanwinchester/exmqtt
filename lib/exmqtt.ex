defmodule ExMQTT do
  @moduledoc """
  Documentation for MQTT client.
  """
  @behaviour ExMQTT.DisconnectHandler
  @behaviour ExMQTT.MessageHandler
  @behaviour ExMQTT.PubAckHandler
  @behaviour ExMQTT.PublishHandler

  use GenServer

  require Logger

  defmodule State do
    defstruct [:conn_pid, :username, :client_id, :message_handler, :opts, :protocol_version, :reconnect, :subscriptions]
  end

  @type opts :: [
    {:name, atom}
    | {:owner, pid}
    | {:message_handler, module}
    | {:puback_handler, module}
    | {:publish_handler, module}
    | {:disconnect_handler, module}
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
    | {:reconnect, {delay :: non_neg_integer, max_delay :: non_neg_integer}}
    | {:subscriptions, [{topic :: binary, qos :: non_neg_integer}]}
    | {:start_when, {mfa, retry_in :: non_neg_integer}}
  ]

  @opt_keys [
    :name,
    :owner,
    :message_handler,
    :puback_handler,
    :publish_handler,
    :disconnect_handler,
    :host,
    :hosts,
    :port,
    :tcp_opts,
    :ssl,
    :ssl_opts,
    :ws_path,
    :connect_timeout,
    :bridge_mode,
    :client_id,
    :clean_start,
    :username,
    :password,
    :protocol_version,
    :keepalive,
    :max_inflight,
    :retry_interval,
    :will_topic,
    :will_payload,
    :will_retain,
    :will_qos,
    :will_props,
    :auto_ack,
    :ack_timeout,
    :force_ping,
    :opts,
    :properties,
    :reconnect,
    :subscriptions,
    :start_when
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

  @impl GenServer
  def init(opts) do
    opts = take_opts(opts)
    {{dc_handler, dc_arg}, opts} = Keyword.pop(opts, :disconnect_handler, {__MODULE__, []})
    {{msg_handler, msg_arg}, opts} = Keyword.pop(opts, :message_handler, {__MODULE__, []})
    {{puback_handler, puback_arg}, opts} = Keyword.pop(opts, :puback_handler, {__MODULE__, []})
    {{publish_handler, pub_arg}, opts} = Keyword.pop(opts, :publish_handler, {__MODULE__, []})
    {{delay, max_delay}, opts} = Keyword.pop(opts, :reconnect, {2000, 60_000})
    {start_when, opts} = Keyword.pop(opts, :start_when, :now)
    {subscriptions, opts} = Keyword.pop(opts, :subscriptions, [])

    # EMQTT `msg_handler` functions
    handler_functions = %{
      puback: &apply(puback_handler, :handle_puback, [&1, puback_arg]),
      publish: &apply(publish_handler, :handle_publish, [&1, pub_arg]),
      disconnected: &apply(dc_handler, :handle_disconnect, [&1, dc_arg])
    }

    state = %State{
      client_id: opts[:client_id],
      message_handler: &apply(msg_handler, :handle_message, [&1, &2, msg_arg]),
      protocol_version: opts[:protocol_version],
      reconnect: {delay, max_delay},
      subscriptions: subscriptions,
      username: opts[:username],
      opts: [{:msg_handler, handler_functions} | opts]
    }

    {:ok, state, {:continue, {:start_when, start_when}}}
  end

  ## Continue

  @impl GenServer

  def handle_continue({:start_when, :now}, state) do
    {:noreply, state, {:continue, {:connect, 0}}}
  end

  def handle_continue({:start_when, start_when}, state) do
    {{module, function, args}, retry_in} = start_when

    if apply(module, function, args) do
      {:noreply, state, {:continue, {:connect, 0}}}
    else
      Process.sleep(retry_in)
      {:noreply, state, {:continue, {:start_when, start_when}}}
    end
  end

  def handle_continue({:connect, attempt}, state) do
    case connect(state) do
      {:ok, state} ->
        :ok = sub(state, state.subscriptions)
        {:noreply, state}

      {:error, _reason} ->
        %{reconnect: {initial_delay, max_delay}} = state
        delay = retry_delay(initial_delay, max_delay, attempt)
        Logger.debug("[ExMQTT] Unable to connect, retrying in #{delay} ms")
        :timer.sleep(delay)
        {:noreply, state, {:continue, {:connect, attempt + 1}}}
    end
  end

  ## Call

  @impl GenServer

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

  @impl GenServer

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

  @impl GenServer

  def handle_info({:publish, packet}, state) do
    %{payload: payload, topic: topic} = packet

    Logger.debug("[ExMQTT] Message received for #{topic}")

    if msg_handler = state.handlers[:message] do
      :ok = msg_handler.(String.split(topic, "/"), payload)
    end

    {:noreply, state}
  end

  def handle_info({:disconnected, :shutdown, :ssl_closed}, state) do
    Logger.warn("[ExMQTT] Disconnected - shutdown, :ssl_closed")
    {:noreply, state}
  end

  def handle_info({:reconnect, attempt}, %{reconnect: {initial_delay, max_delay}} = state) do
    Logger.debug("[ExMQTT] Trying to reconnect")

    case connect(state) do
      {:ok, state} ->
        Logger.debug("[ExMQTT] Connected #{inspect(state.conn_pid)}")
        {:noreply, state}

      {:error, _reason} ->
        delay = retry_delay(initial_delay, max_delay, attempt)
        Process.send_after(self(), {:reconnect, attempt + 1}, delay)
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warn("[ExMQTT] Unhandled message #{inspect(msg)}")
    {:noreply, state}
  end

  ## Disconnect

  @impl ExMQTT.DisconnectHandler
  def handle_disconnect({reason_code, properties}, _arg) do
    Logger.warn("[ExMQTT] Disconnect received: reason #{reason_code}, properties: #{inspect(properties)}")

    # Process.send_after(self(), {:reconnect, 0}, 500)

    :ok
  end

  ## Message

  @impl ExMQTT.MessageHandler
  def handle_message(_topic, _message, _arg) do
    Logger.warn("[ExMQTT] Message received but no handler module defined")
    :ok
  end

  ## PubAck

  @impl ExMQTT.PubAckHandler
  def handle_puback(ack, _arg) do
    Logger.debug("[ExMQTT] PUBACK received #{inspect(ack)}")
    :ok
  end

  ## Publish

  @impl ExMQTT.PublishHandler
  def handle_publish(message, _arg) do
    Logger.debug("[ExMQTT] Publish: #{inspect(message)}")
    :ok
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp connect(%State{} = state) do
    Logger.debug("[ExMQTT] Connecting to #{state.opts[:host]}:#{state.opts[:port]}")

    opts = map_opts(state.opts)

    with(
      {:ok, conn_pid} when is_pid(conn_pid) <- :emqtt.start_link(opts),
      {:ok, _props} <- :emqtt.connect(conn_pid)
    ) do
      Logger.debug("[ExMQTT] Connected #{inspect(conn_pid)}")
      {:ok, %State{state | conn_pid: conn_pid}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:ok, res} ->
        {:error, res}
    end
  end

  defp pub(%State{} = state, message, topic, qos) do
    if qos == 0 do
      :ok = :emqtt.publish(state.conn_pid, topic, message, qos)
    else
      {:ok, _packet_id} = :emqtt.publish(state.conn_pid, topic, message, qos)
    end
  end

  defp sub(%State{} = state, topics) when is_list(topics) do
    Enum.each(topics, fn {topic, qos} ->
      :ok = sub(state, topic, qos)
    end)
  end

  defp sub(%State{} = state, topic, qos) do
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

  defp unsub(%State{} = state, topic) do
    case :emqtt.unsubscribe(state.conn_pid, topic) do
      {:ok, _props, [0x00]} ->
        Logger.debug("[ExMQTT] Unsubscribed from #{topic}")
        :ok

      {:ok, _props, reason_codes} ->
        Logger.error("[ExMQTT] Unsubscribe from #{topic} failed #{inspect(reason_codes)}")
        :error
    end
  end

  defp dc(%State{} = state) do
    :ok = :emqtt.disconnect(state.conn_pid)
  end

  ## Utility

  defp take_opts(opts) do
    case Keyword.split(opts, @opt_keys) do
      {keep, []} -> keep
      {_keep, extra} -> raise ArgumentError, "Unrecognized options #{Enum.join(extra, ", ")}"
    end
  end

  # Backoff with full jitter (after 3 attempts).
  defp retry_delay(initial_delay, _max_delay, attempt) when attempt < 3 do
    initial_delay
  end

  defp retry_delay(initial_delay, max_delay, attempt) when attempt < 1000 do
    temp = min(max_delay, pow(initial_delay * 2, attempt))
    temp / 2 + Enum.random([0, temp / 2])
  end

  defp retry_delay(_initial_delay, max_delay, _attempt) do
    max_delay
  end

  # Integer powers:
  # https://stackoverflow.com/a/44065965/2066155
  defp pow(n, k), do: pow(n, k, 1)
  defp pow(_, 0, acc), do: acc
  defp pow(n, k, acc), do: pow(n, k - 1, n * acc)

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
