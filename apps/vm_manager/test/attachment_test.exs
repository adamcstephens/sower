defmodule VMManager.AttachmentTest do
  use ExUnit.Case, async: true

  for {scenario, state, id, device_tree} <- [
        {"another VM", "Running", "other", nil},
        {"an allocated Created VM", "Created", "expected", %{"devices" => []}}
      ] do
    test "an endpoint serving #{scenario} is retained without mutation or path cleanup" do
      native_state = unquote(state)
      native_id = unquote(id)
      device_tree = unquote(Macro.escape(device_tree))
      directory = Path.join(System.tmp_dir!(), "vm-attach-#{System.unique_integer([:positive])}")
      File.mkdir!(directory)
      control = Path.join(directory, "control.sock")
      guest = Path.join(directory, "guest.sock")
      marker = Path.join(directory, "external-data")
      File.write!(marker, "keep")

      {:ok, listener} =
        :gen_tcp.listen(
          0,
          [:binary, active: false, packet: :line, ifaddr: {:local, control}]
        )

      on_exit(fn ->
        :gen_tcp.close(listener)
        File.rm_rf!(directory)
      end)

      parent = self()

      {server, monitor} =
        spawn_monitor(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          assert {:ok, "GET /api/v1/vm.info HTTP/1.1\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
          headers(socket)

          body =
            Jason.encode!(%{
              "state" => native_state,
              "device_tree" => device_tree,
              "memory_actual_size" => 536_870_912,
              "config" => %{
                "payload" => %{
                  "kernel" => "/kernel",
                  "initramfs" => "/initrd",
                  "cmdline" => "sower.vm.id=#{native_id}"
                },
                "cpus" => %{"boot_vcpus" => 1},
                "memory" => %{"size" => 536_870_912},
                "disks" => [%{"path" => "/root"}],
                "vsock" => %{"socket" => guest},
                "net" => []
              }
            })

          :ok =
            :gen_tcp.send(
              socket,
              [
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
                to_string(byte_size(body)),
                "\r\nconnection: close\r\n\r\n",
                body
              ]
            )

          :gen_tcp.close(socket)
          send(parent, :identity_observed)
          assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
        end)

      config = %VMManager.Config{
        id: "expected",
        kernel: "/kernel",
        initrd: "/initrd",
        disks: [%CloudHypervisor.Config.Disk{path: "/root", readonly: true, image_type: :raw}],
        guest: %VMManager.Config.SowerGuest{},
        vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: guest},
        mode: :attach,
        control_endpoint: control
      }

      {:ok, execution} = VMManager.Execution.start_link(VMManager.Config.to_options(config))
      on_exit(fn -> if Process.alive?(execution), do: GenServer.stop(execution) end)

      assert {:error,
              {:cleanup_unconfirmed, {:error, {:attachment, :runtime_identity_mismatch}},
               :unconfirmed, nil}} =
               GenServer.call(execution, :await, 1_000)

      assert_receive :identity_observed
      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 1_000
      assert File.read!(marker) == "keep"
      assert File.exists?(control)

      assert %VMManager.Status{phase: :retained, cleanup: :unconfirmed} =
               GenServer.call(execution, :status)
    end
  end

  test "boots the existing Created VM and certifies shutdown by observing Created again" do
    directory = Path.join(System.tmp_dir!(), "vm-created-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    control = Path.join(directory, "control.sock")
    guest = Path.join(directory, "guest.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, control}])

    {:ok, bridge} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, guest}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      :gen_tcp.close(bridge)
      File.rm_rf!(directory)
    end)

    config = %VMManager.Config{
      id: "existing",
      kernel: "/kernel",
      initrd: "/initrd",
      disks: [%CloudHypervisor.Config.Disk{path: "/root", readonly: true, image_type: :raw}],
      guest: %VMManager.Config.SowerGuest{},
      vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: guest},
      mode: :attach,
      control_endpoint: control
    }

    native_config = %{
      "payload" => %{
        "kernel" => config.kernel,
        "initramfs" => config.initrd,
        "cmdline" => " sower.vm.id=existing"
      },
      "cpus" => %{"boot_vcpus" => config.cpus, "max_vcpus" => config.cpus},
      "memory" => %{"size" => config.memory},
      "disks" => [%{"path" => "/root", "readonly" => true, "image_type" => "Raw"}],
      "vsock" => %{"cid" => 3, "socket" => guest},
      "net" => []
    }

    info = fn state ->
      Jason.encode!(%{
        "state" => state,
        "device_tree" => nil,
        "config" => native_config,
        "memory_actual_size" => config.memory
      })
    end

    allocated_created =
      Jason.encode!(%{
        "state" => "Created",
        "device_tree" => %{"devices" => []},
        "config" => native_config,
        "memory_actual_size" => config.memory
      })

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)

        for {method, endpoint, status, body} <- [
              {"GET", "vm.info", 200, info.("Created")},
              {"PUT", "vm.boot", 204, ""},
              {"GET", "vm.info", 200, info.("Running")},
              {"GET", "vm.info", 200, info.("Running")},
              {"PUT", "vm.power-button", 204, ""},
              {"GET", "vm.info", 200, allocated_created},
              {"GET", "vm.info", 200, info.("Created")}
            ] do
          assert {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
          assert line == "#{method} /api/v1/#{endpoint} HTTP/1.1\r\n"
          headers(socket)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 #{status} OK\r\ncontent-type: application/json\r\ncontent-length: ",
              to_string(byte_size(body)),
              "\r\n\r\n",
              body
            ])
        end

        :gen_tcp.close(socket)
      end)

    parent = self()

    guest_task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(bridge, 5_000)
        assert {:ok, "CONNECT 5000\n"} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "OK 5000\n")
        :ok = :inet.setopts(socket, packet: :raw)
        send(parent, {:guest_connected, self()})

        receive do
          :release_ready -> :ok
        end

        ready = Jason.encode!(%{"type" => "ready", "version" => 2, "contract" => 2})
        :ok = :gen_tcp.send(socket, <<1, byte_size(ready)::unsigned-big-32, ready::binary>>)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      end)

    {:ok, execution} = VMManager.Execution.start_link(VMManager.Config.to_options(config))
    on_exit(fn -> if Process.alive?(execution), do: GenServer.stop(execution) end)

    assert {:ok, %VMManager.Status{phase: :booting, running: true}} =
             GenServer.call(execution, :await_running, 5_000)

    assert_receive {:guest_connected, guest_pid}, 5_000
    send(guest_pid, :release_ready)

    assert {:ok, %VMManager.Status{phase: :ready}} =
             GenServer.call(execution, :await_ready, 5_000)

    assert :ok = GenServer.call(execution, {:stop, %VMManager.Stop{}}, 5_000)
    assert %VMManager.Status{phase: :stopped, cleanup: :ok} = GenServer.call(execution, :status)
    Task.await(server)
    Task.await(guest_task)
    assert File.exists?(control)
    assert File.exists?(guest)
    assert File.dir?(directory)
  end

  for outcome <- [:shutdown, :endpoint_loss, :liveness_loss, :identity_change] do
    test "agentless attachment observes external #{outcome} without guest IO" do
      observe_external_runtime(unquote(outcome))
    end
  end

  for {scenario, observations} <- [
        {:transient_timeout, [:timeout, :healthy, :shutdown]},
        {:reset_timeout_budget, [:timeout, :timeout, :healthy, :timeout, :timeout, :shutdown]},
        {:sustained_timeouts, [:timeout, :timeout, :timeout]},
        {:refused_after_timeout, [:timeout, :refuse]},
        {:foreign_after_timeout, [:timeout, :foreign]}
      ] do
    test "attachment observation handles #{scenario} without runtime mutation" do
      observe_timeout_sequence(unquote(Macro.escape(observations)))
    end
  end

  defp observe_timeout_sequence(observations) do
    directory = Path.join(System.tmp_dir!(), "vm-timeout-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    control = Path.join(directory, "control.sock")
    marker = Path.join(directory, "external-data")
    File.write!(marker, "keep")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, control}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(directory)
    end)

    config = %VMManager.Config{
      id: "observed",
      kernel: "/kernel",
      guest: :none,
      mode: :attach,
      control_endpoint: control
    }

    parent = self()

    peer =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, socket} = :gen_tcp.accept(listener, 2_000)
             observation_request(socket)
             native_reply(socket, config, "Running", "observed")
             send(parent, :attachment_admitted)

             Enum.reduce(observations, socket, fn
               :refuse, nil ->
                 :gen_tcp.close(listener)
                 send(parent, :endpoint_refused)
                 nil

               observation, previous ->
                 socket =
                   if previous do
                     previous
                   else
                     {:ok, connected} = :gen_tcp.accept(listener, 2_000)
                     connected
                   end

                 observation_request(socket)

                 case observation do
                   :timeout ->
                     assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
                     :gen_tcp.close(socket)
                     send(parent, :request_timed_out)
                     nil

                   :healthy ->
                     native_reply(socket, config, "Running", "observed")
                     observation_request(socket)
                     send(parent, {:healthy_observed, self()})

                     receive do
                       :continue_observation -> :ok
                     end

                     native_reply(socket, config, "Running", "observed")
                     socket

                   :shutdown ->
                     native_reply(socket, config, "Created", "observed")
                     assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
                     :gen_tcp.close(socket)
                     nil

                   :foreign ->
                     native_reply(socket, config, "Running", "foreign")
                     assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
                     :gen_tcp.close(socket)
                     nil
                 end
             end)

             send(parent, :observations_finished)
           end},
          restart: :temporary
        )
      )

    execution = start_supervised!({VMManager.Execution, VMManager.Config.to_options(config)})
    assert_receive :attachment_admitted, 2_000

    assert {:ok, %VMManager.Status{phase: :running, running: true}} =
             GenServer.call(execution, :await_running, 1_000)

    for observation <- observations do
      case observation do
        :timeout ->
          assert_receive :request_timed_out, 2_000

        :healthy ->
          assert_receive {:healthy_observed, ^peer}, 2_000

          assert %VMManager.Status{phase: :running, running: true} =
                   GenServer.call(execution, :status)

          send(peer, :continue_observation)

        :refuse ->
          assert_receive :endpoint_refused, 2_000

        _ ->
          :ok
      end
    end

    if List.last(observations) == :shutdown do
      assert {:ok, :external_shutdown} = GenServer.call(execution, :await, 3_000)

      assert %VMManager.Status{phase: :stopped, cleanup: :ok} =
               GenServer.call(execution, :status)
    else
      assert {:error, {:cleanup_unconfirmed, _, _, _}} =
               GenServer.call(execution, :await, 3_000)

      assert %VMManager.Status{phase: :retained, running: false, cleanup: :unconfirmed} =
               GenServer.call(execution, :status)
    end

    assert_receive :observations_finished, 2_000
    assert File.read!(marker) == "keep"
    assert File.exists?(control)
  end

  defp observation_request(socket) do
    assert {:ok, "GET /api/v1/vm.info HTTP/1.1\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    headers(socket)
  end

  defp observe_external_runtime(outcome) do
    directory = Path.join(System.tmp_dir!(), "vm-observe-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    control = Path.join(directory, "control.sock")
    marker = Path.join(directory, "external-data")
    File.write!(marker, "keep")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, control}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(directory)
    end)

    config = %VMManager.Config{
      id: "observed",
      kernel: "/kernel",
      guest: :none,
      mode: :attach,
      control_endpoint: control
    }

    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        assert {:ok, "GET /api/v1/vm.info HTTP/1.1\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
        headers(socket)
        send(parent, :attachment_admitted)
        native_reply(socket, config, "Running", "observed")

        receive do
          :change_runtime -> :ok
        end

        if outcome == :endpoint_loss do
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        else
          assert {:ok, "GET /api/v1/vm.info HTTP/1.1\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
          headers(socket)

          case outcome do
            :shutdown ->
              native_reply(socket, config, "Created", "observed")

            :identity_change ->
              native_reply(socket, config, "Running", "foreign")

            :liveness_loss ->
              send(parent, :observation_waiting)

              receive do
                :release_observation -> :ok
              end
          end

          if outcome != :liveness_loss,
            do: assert({:error, :timeout} = :gen_tcp.recv(socket, 0, 100))

          :gen_tcp.close(socket)
        end
      end)

    execution = start_supervised!({VMManager.Execution, VMManager.Config.to_options(config)})

    assert {:ok, %VMManager.Status{phase: :running, running: true}} =
             GenServer.call(execution, :await_running, 1_000)

    assert_receive :attachment_admitted

    send(peer.pid, :change_runtime)
    if outcome == :liveness_loss, do: assert_receive(:observation_waiting, 2_000)

    if outcome == :shutdown do
      assert {:ok, _} = GenServer.call(execution, :await, 3_000)

      assert %VMManager.Status{phase: :stopped, running: false, cleanup: :ok} =
               GenServer.call(execution, :status)
    else
      assert {:error, {:cleanup_unconfirmed, _, _, _}} =
               GenServer.call(execution, :await, 3_000)

      assert %VMManager.Status{phase: :retained, running: false} =
               GenServer.call(execution, :status)
    end

    send(peer.pid, :release_observation)

    Task.await(peer)
    assert File.read!(marker) == "keep"
  end

  defp native_reply(socket, config, state, id) do
    body =
      Jason.encode!(%{
        "state" => state,
        "device_tree" => nil,
        "memory_actual_size" => config.memory,
        "config" =>
          config
          |> VMManager.Machine.build(nil, config.network)
          |> CloudHypervisor.Config.to_api()
          |> put_in(["payload", "cmdline"], config.cmdline <> " sower.vm.id=#{id}")
      })

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
        to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])
  end

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> headers(socket)
    end
  end
end
