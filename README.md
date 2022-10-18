# ExMQTT

An Elixir wrapper around the Erlang [`emqtt`](https://github.com/emqx/emqtt) library.

Why this package?

 * supports MQTT v3.0, v3.1.1, and v5.0
 * supports clean_session/clean_start
 * simplifies usage to just defining opts and implementing a message handler

## Installation

The package can be installed by adding `exmqtt` to your list of dependencies in
`mix.exs`:

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

**Note:** This is not available in hex, and there are no plans to do so unless
`emqtt` starts consistently and reliably publishing to hex (they do publish to
hex but not consistently and reliably).

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
{:protocol_version, 3 | 4 | 5}
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
{:start_when, {mfa, retry_in :: non_neg_integer}}
```

**Note:**

 * The `opts` are *mostly* the same as [`:emqtt.option()`](https://github.com/emqx/emqtt/blob/783c943f7aa1295b99f4a0c20436978eb6b70053/src/emqtt.erl#L105), but they are different, so use the type defs in this library
 * `opts.ssl_opts` are erlang's [`:ssl.option()`](https://erlang.org/doc/man/ssl.html#type-tls_client_option)
 * `opts.handler_functions` type is defined [here](https://github.com/ryanwinchester/exmqtt/blob/b404a86bc3612b23bb32008776de09efa1fee69c/lib/exmqtt.ex#L13)
 * `opts.start_when` is for controller the GenServer's `handle_continue/2` callback, so you can add an
 init condition. This is handy for example if you need to wait for the network to be ready before you try to connect to the MQTT broker. The value is a tuple `{start_when, retry_in}` where `start_when` is a `{module, function, arguments}` (MFA) tuple for a function that resolves to a `boolean` which determines when we actually finish `init`, and `retry_in` is the time to sleep (in ms) before we try again.

#### Example `opts` for SSL connection:

```elixir
[
  host: "127.0.0.1",
  port: 8883,
  protocol_version: 5,
  ssl: true,
  client_id: "client-02",
  username: "user-01",
  password: "mysecretprivates",
  clean_start: false,
  ssl_opts: [
    cacertfile: '/etc/mqtt/certs/all-ca.crt',
    keyfile: '/etc/mqtt/certs/client.key',
    certfile: '/etc/mqtt/certs/client.crt'
  ],
  start_when: {{MyProject.Network, :connected?, []}, 2000},
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
  @behaviour ExMQTT.MessageHandler

  @impl true
  def handle_message(["foo", "bar"], message, _extra) do
    # Matches on "foo/bar"
  end

  def handle_message(["foo", "bar" | _rest], message, _extra) do
    # Matches on "foo/bar/#"
  end

  def handle_message(["baz", buzz], message, _extra) do
    # Matches on "baz/+"
  end

  def handle_message(topic, message, _extra) do
    # Catch-all
  end
end
```
