defmodule ClientRunner do
  use GenServer
  require Logger

  defmacro ae_url, do: Application.get_env(:ae_socket_connector, :node)[:ae_url]

  defmacro network_id, do: Application.get_env(:ae_socket_connector, :node)[:network_id]

  defstruct pid_session_holder: nil,
            color: nil,
            match_list: nil,
            role: nil,
            fuzzy_counter: 0,
            paused: false

  def start_link(
        {_pub_key, _priv_key, _state_channel_configuration, _log_config, _ae_url, _network_id, _role, _jobs, _color, _name} =
          params
      ) do
    GenServer.start_link(__MODULE__, params)
  end

  defp log_callback(type, round, round_initiator, method, color) do
    Logger.debug(
      "received: #{inspect {type, round, round_initiator, method}} pid is: #{inspect self()}",
      color
    )
  end

  def connection_callback(callback_pid, color) do
    %SocketConnector.ConnectionCallbacks{
      sign_approve: fn round_initiator, round, auto_approval, method, to_sign, human ->
        Logger.debug(
          ":sign_approve, #{inspect(round)}, #{inspect(method)} extras: to_sign #{inspect(to_sign)} auto_approval: #{
            inspect(auto_approval)
          }, human: #{inspect(human)}, initiator #{inspect(round_initiator)}",
          ansi_color: color
        )

        GenServer.cast(callback_pid, {:match_jobs, {:sign_approve, round, method}, to_sign})
        auto_approval
      end,
      channels_info: fn round_initiator, round, method ->
        log_callback(:channels_info, round, round_initiator, method, ansi_color: color)
        GenServer.cast(callback_pid, {:match_jobs, {:channels_info, round, round_initiator, method}, nil})
      end,
      channels_update: fn round_initiator, round, method ->
        log_callback(:channels_update, round, round_initiator, method, ansi_color: color)
        GenServer.cast(callback_pid, {:match_jobs, {:channels_update, round, round_initiator, method}, nil})
      end,
      on_chain: fn round_initiator, round, method ->
        Logger.debug(
          "on_chain received round is: #{inspect(round)}, initated by: #{inspect(round_initiator)} method is #{
            inspect(method)
          }}",
          ansi_color: color
        )

        GenServer.cast(callback_pid, {:match_jobs, {:on_chain, round, round_initiator, method}, nil})
      end
    }
  end

  def seperate_jobs(job_list) do
    {filter_jobs(job_list, :initiator), filter_jobs(job_list, :responder)}
  end

  def filter_jobs(job_list, role) do
    for {runner, event} <- job_list, runner == role, do: event
  end

  # Server
  def init({pub_key, priv_key, state_channel_configuration, log_config, ae_url, network_id, role, jobs, color, name}) do
    {:ok, pid_session_holder} =
      SessionHolder.start_link(%{
        socket_connector: %{
          pub_key: pub_key,
          session: state_channel_configuration,
          role: role
        },
        log_config: log_config,
        ae_url: ae_url,
        network_id: network_id,
        priv_key: priv_key,
        connection_callbacks: connection_callback(self(), color),
        color: color,
        pid_name: name
      })

    {:ok,
     %__MODULE__{
       pid_session_holder: pid_session_holder,
       match_list: jobs,
       role: role,
       color: [ansi_color: color]
     }}
  end

  def run_next(match) do
    case Map.get(match, :next, false) do
      false ->
        :ok

      job ->
        # Logger.debug("running next", state.color)
        GenServer.cast(self(), {:process_job_lists, job})
    end
  end

  def process_sign_request(message, to_sign, pid_session_holder, mode \\ %{sign: {:default}})

  def process_sign_request({}, _to_sign, _pid_session_holder, _mode) do
    Logger.debug("Empty request")
  end

  def process_sign_request(message, to_sign, pid_session_holder, %{sign: sign_info}) do
    case elem(message, 0) do
      :sign_approve ->
        case sign_info do
          {:default} ->
            signed = SessionHolder.sign_message(pid_session_holder, to_sign)
            fun = &(SocketConnector.send_signed_message(&1, elem(message, 2), signed))
            SessionHolder.run_action(pid_session_holder, fun)

          {:backchannel, pid_other_session_holder} ->
            signed = SessionHolder.sign_message(pid_session_holder, to_sign)
            signed2 = SessionHolder.sign_message(pid_other_session_holder, signed)
            fun = &(SocketConnector.send_signed_message(&1, elem(message, 2), signed2))
            SessionHolder.run_action(pid_session_holder, fun)

          {:check_poi} ->
            fun = &SocketConnector.get_poi/2
            poi = SessionHolder.run_action_sync(pid_session_holder, fun)

            case SessionHolder.verify_poi(pid_session_holder, to_sign, poi) do
              :ok ->
                signed = SessionHolder.sign_message(pid_session_holder, to_sign)
                fun = fn pid -> SocketConnector.send_signed_message(pid, elem(message, 2), signed) end
                SessionHolder.run_action(pid_session_holder, fun)

              :unsecure ->
                Logger.warn("POI missmatch, refuse signing")
            end

          {:abort, abort_code} ->
            method = elem(message, 2)
            fun = &SocketConnector.abort(&1, method, abort_code, "some message")
            SessionHolder.run_action(pid_session_holder, fun)

          _ ->
            Logger.debug("Don't sign")
        end

      _ ->
        :ok
    end
  end

  def process_sign_request(message, to_sign, pid_session_holder, _not_sign_request) do
    process_sign_request(message, to_sign, pid_session_holder)
  end

  def handle_cast({:end_pause}, state) do
    GenServer.cast(self(), {:match_jobs, {}, nil})
    {:noreply, %__MODULE__{state | paused: false}}
  end

  def handle_cast({:match_jobs, received_message, _to_sign}, %__MODULE__{paused: true} = state) do
    Logger.debug(
      "PAUSED role: #{inspect(state.role)} ignoring message #{inspect(received_message)}",
      state.color
    )

    {:noreply, state}
  end

  # message is mandated in every entry
  def handle_cast({:match_jobs, received_message, to_sign}, state) do
    case state.match_list do
      [%{message: expected} = entry | rest] ->
        Logger.debug(
          "match: #{inspect(expected == received_message)} role: #{inspect(state.role)} expected #{
            inspect(expected)
          } received #{inspect(received_message)}",
          state.color
        )

        process_sign_request(received_message, to_sign, state.pid_session_holder, entry)

        case expected == received_message do
          true ->
            run_next(entry)
            {:noreply, %__MODULE__{state | match_list: rest, fuzzy_counter: 0}}

          false ->
            case Map.get(entry, :fuzzy, 0) do
              0 ->
                throw("message not matching")

              value ->
                case state.fuzzy_counter >= value do
                  true ->
                    throw(
                      "message role #{inspect(state.role)} #{inspect(expected)}, last received is #{
                        inspect(received_message)
                      } has not arrived, waited for #{inspect(state.fuzzy_counter)} max wait #{inspect(value)}"
                    )

                  false ->
                    Logger.debug(
                      "adding to counter... #{inspect(state.fuzzy_counter)} max wait #{inspect(value)}",
                      state.color
                    )

                    {:noreply, %__MODULE__{state | fuzzy_counter: state.fuzzy_counter + 1}}
                end
            end
        end

      [%{next: _next} = entry | rest] ->
        process_sign_request(received_message, to_sign, state.pid_session_holder, entry)
        run_next(entry)
        {:noreply, %__MODULE__{state | match_list: rest, fuzzy_counter: 0}}

      [] ->
        process_sign_request(received_message, to_sign, state.pid_session_holder)
        Logger.debug("list reached end", state.color)
        {:noreply, state}
    end
  end

  def handle_cast({:process_job_lists, next}, state) do
    {mode, fun, assert_fun} = next

    case mode do
      :async ->
        SessionHolder.run_action(state.pid_session_holder, fun)
        {:noreply, state}

      :sync ->
        response = SessionHolder.run_action_sync(state.pid_session_holder, fun)

        case assert_fun do
          :empty -> :empty
          _ -> assert_fun.(response)
        end

        GenServer.cast(self(), {:match_jobs, {}, nil})
        {:noreply, state}

      :local ->
        fun.(self(), state.pid_session_holder)
        {:noreply, state}

      :pause ->
        fun.(self(), state.pid_session_holder)
        Logger.debug("role: #{inspect(state.role)} entering pause")
        {:noreply, %__MODULE__{state | paused: true}}
    end
  end

  def gen_name(name, suffix) do
    String.to_atom(to_string(name) <> Integer.to_string(suffix))
  end

  # elimiation overlap yields issues, need to be investigated
  @grace_period_ms 2000

  def start_helper(ae_url, network_id, initiator_keys, responder_keys, joblist) do
    Enum.each(Enum.zip(joblist, 1..Enum.count(joblist)), fn {fun, suffix} ->
      Logger.info("Launching next job in queue")

      start_peers(
        ae_url,
        network_id,
        {gen_name(:alice, suffix), initiator_keys},
        {gen_name(:bob, suffix), responder_keys},
        fun
      )

      Process.sleep(@grace_period_ms)
    end)
  end

  def await_finish([]) do
    Logger.debug("Scenario reached end")
  end

  def await_finish(expected_messages) do
    receive do
      {:test_finished, name} ->
        reduced_list = List.delete(expected_messages, name)

        Logger.debug("Received message from runner: #{inspect(name)} remaining: #{inspect(reduced_list)}")

        await_finish(reduced_list)
    end
  end

  def custom_connection_setting(role, _host_url) do
    same = %{
      channel_reserve: "2",
      lock_period: "10",
      port: "1500",
      protocol: "json-rpc",
      push_amount: "1",
      minimum_depth: 0,
      role: role
    }

    role_map =
      case role do
        :initiator ->
          # %URI{host: host} = URI.parse(host_url)
          # TODO Worksound to be able to connect to testnet
          # %{host: host, role: "initiator"}
          %{host: "localhost"}

        _ ->
          %{}
      end

    Map.merge(same, role_map)
  end

  def default_configuration(initiator_pub, responder_pub) do
    %{
      basic_configuration: %SocketConnector.WsConnection{
        initiator_id: initiator_pub,
        initiator_amount: 7_000_000_000_000,
        responder_id: responder_pub,
        responder_amount: 4_000_000_000_000
      },
      custom_param_fun: &custom_connection_setting/2
    }
  end

  def start_peers(
        ae_url,
        network_id,
        {name_initiator, {initiator_pub, initiator_priv}, initiator_log_config},
        {name_responder, {responder_pub, responder_priv}, responder_log_config},
        job_builder,
        channel_configuration \\ &default_configuration/2
      ) do
    Logger.debug("executing test: #{inspect(job_builder)}")

    {jobs_initiator, jobs_responder} =
      seperate_jobs(job_builder.({name_initiator, initiator_pub}, {name_responder, responder_pub}, self()))

    state_channel_configuration = channel_configuration.(initiator_pub, responder_pub)

    start_link(
      {initiator_pub, initiator_priv, state_channel_configuration, initiator_log_config, ae_url, network_id, :initiator, jobs_initiator,
       :yellow, name_initiator}
    )

    start_link(
      {responder_pub, responder_priv, state_channel_configuration, responder_log_config, ae_url, network_id, :responder, jobs_responder,
       :blue, name_responder}
    )

    await_finish([name_initiator, name_responder])
  end
end
