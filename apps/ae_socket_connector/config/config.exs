use Mix.Config

config :logger,
  compile_time_purge_matching: [
    [module: SocketConnector, level_lower_than: :error]
  ]

config :ae_socket_connector, :node,
  ae_url: System.get_env("AE_NODE_URL") || "ws://localhost:3014/channel",
  network_id: System.get_env("AE_NODE_NETWORK_ID") || "ae_channel_service_test"
