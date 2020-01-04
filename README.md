# ExMQTT

An Elixir wrapper around the erlang [`emqtt`](https://github.com/emqx/emqtt) library.

Why this package?

 * supports MQTT v3.0, v3.1.1, and v5.0
 * supports clean_session/clean_start
 * simplifies usage to just defining opts and implementing a message handler

## Installation

The package can be installed
by adding `exmqtt` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:exmqtt, github: "ryanwinchester/exmqtt", branch: "master"}
  ]
end
```

Sometimes you might have dependency issues because of the `emqtt` dependencies
using git links and tags (see: https://github.com/emqx/emqtt/issues/100),
so you might need to do:

```elixir
def deps do
  [
    {:exmqtt, github: "ryanwinchester/exmqtt", branch: "master"},
    {:gun, "~> 1.3.0", override: true},
    {:cowlib, "~> 2.6.0", override: true}
  ]
end
```

## Usage

### Starting the client

You can use the `GenServer` or the `Supervisor` like so:

```elixir
ExMQTT.start_link(opts)
```
or 

```elixir
ExMQTT.Supervisor.start_link(opts)
```

You probably just want to add either to your application's supervision tree.

### Using the client

```elixir
ExMQTT.publish(message, topic, qos)

ExMQTT.subscribe(topic, qos)

ExMQTT.unsubscribe(topic)

ExMQTT.publish_sync(message, topic, qos)

ExMQTT.subscribe_sync(topic, qos)

ExMQTT.unsubscribe_sync(topic)
```

### `opts`

```elixir
{:name, atom}
{:owner, pid}
{:handler_module, module}
{:handler_functions, handler_functions}
{:host, binary}
{:hosts, [{binary, :inet.port_number()}]}
{:port, :inet.port_number()}
{:tcp_opts, [:gen_tcp.option()]}
{:ssl, boolean}
{:ssl_opts, [:ssl.ssl_option()]}
{:ws_path, binary}
{:connect_timeout, pos_integer}
{:bridge_mode, boolean}
{:client_id, iodata}
{:clean_start, boolean}
{:username, iodata}
{:password, iodata}
{:protocol_version, :v3 | :v4 | :v5}
{:keepalive, non_neg_integer}
{:max_inflight, pos_integer}
{:retry_interval, timeout}
{:will_topic, iodata}
{:will_payload, iodata}
{:will_retain, boolean}
{:will_qos, pos_integer}
{:will_props, %{atom => term}}
{:auto_ack, boolean}
{:ack_timeout, pos_integer}
{:force_ping, boolean}
{:properties, %{atom => term}}
{:subscriptions, [{topic :: binary, qos :: non_neg_integer}]}
```

#### Example `opts` for SSL connection:

```elixir
[
  host: "127.0.0.1",
  port: 8883,
  protocol_version: 5,
  ssl: true,
  client_id: "client-02",
  username: "user-01",
  clean_start: false,
  ssl_opts: [
    cacertfile: '/etc/mqtt/certs/all-ca.crt',
    keyfile: '/etc/mqtt/certs/client.key',
    certfile: '/etc/mqtt/certs/client.crt'
  ],
  handler_module: MyApp.MQTTMessageHandler,
  subscriptions: [
    {"foo/#", 1},
    {"baz/+", 0}
  ]
]
```

### Message Handler module

```elixir
defmodule MyApp.MQTTMessageHandler do
  @behaviour ExMQTT.Handler

  @impl true
  def handle_message(["foo", "bar"], message) do
    # Matches on "foo/bar"
  end

  def handle_message(["foo", "bar" | _rest], message) do
    # Matches on "foo/bar/#"
  end

  def handle_message(["baz", buzz], message) do
    # Matches on "baz/+"
  end

  def handle_message(topic, message) do
    # Catch-all
  end
end
```
