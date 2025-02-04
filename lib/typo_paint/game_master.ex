defmodule TypoPaint.GameMaster do
  use GenServer

  alias TypoPaint.{
    Game,
    Course,
    Path,
    PathCharIndex,
    Player,
    Util
  }

  @player_count_limit 3

  @player_colors ["orange", "blue", "green"]

  @game_duration_seconds 60
  @game_update_period 1_000

  def start_link(_init \\ nil) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_init \\ nil) do
    {:ok,
     %{
       games: %{}
     }}
  end

  def handle_info({:notify_game_listeners, game_id}, state) do
    %Game{} = game = get_in(state, [:games, game_id])
    notify_game_listeners(game)
    {:noreply, state}
  end

  def handle_call(:reset_all, _from, _state) do
    {:ok, reset_state} = init()

    {:reply, :ok, reset_state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:new_game, game}, _from, state) do
    with game_id <- UUID.uuid1(),
         game = %Game{} <- initialize_game(game),
         %{} = updated_state <- put_in(state, [:games, game_id], game) do
      {:reply, game_id, updated_state}
    else
      {:error, :invalid_player_color} ->
        {:reply, {:error, "invalid player color"}, state}
    end
  end

  def handle_call({:start_game, game_id}, _from, state) do
    with %Game{players: players, game_duration_seconds: game_duration_seconds} = game <- Kernel.get_in(state, [:games, game_id]),
         now <- Util.now(),
         end_time <- DateTime.add(now, game_duration_seconds, :second),
         {:ok, timer} <- :timer.send_interval(@game_update_period, __MODULE__, {:notify_game_listeners, game_id}),
         updated_game <- %Game{ game | state: :running, end_time: end_time, timer: timer},
         updated_state <- put_in(state, [:games, game_id], updated_game) do
      case {game.state, length(players)} do
        {:pending, player_count} when player_count > 0 ->
          :timer.apply_after(game_duration_seconds * 1000, __MODULE__, :end_game, [game_id])
          {:reply, {:ok, updated_game}, updated_state}

        {_, 0} ->
          {:reply, {:error, "game has no players"}, state}

        {:running, _} ->
          {:reply, {:error, "game already running"}, state}

        {:ended, _} ->
          {:reply, {:error, "game already ended"}, state}
      end
    else
      nil ->
        {:reply, {:error, "game not found"}, state}

      _ ->
        {:reply, {:error, "unknown error"}, state}
    end
  end

  def handle_call({:end_game, game_id}, _from, state) do
    with %Game{state: :running, players: players, timer: timer} = game <-
           Kernel.get_in(state, [:games, game_id]),
         updated_game <- Map.put(game, :state, :ended),
         updated_state <- put_in(state, [:games, game_id], updated_game) do
      :timer.cancel(timer)
      Enum.map(players, fn
        %Player{view_pid: nil} ->
          nil

        %Player{view_pid: view_pid} ->
          send(view_pid, :end_game)
      end)

      {:reply, {:ok, updated_game}, updated_state}
    else
      nil ->
        {:reply, {:error, "game not found"}, state}

      %Game{state: game_state} ->
        {:reply, {:error, "game is #{game_state}, not running"}, state}

      _ ->
        {:reply, {:error, "unknown error"}, state}
    end
  end

  def handle_call({:advance_game, game_id, player_index, key_code}, _from, state) do
    # If key_code fits one of the characters (we'll take the first one found) indexed by the player's
    # cur_path_char_indices, then we can advance.
    with %Game{state: :running, course: course, players: players} = game <-
           Kernel.get_in(state, [:games, game_id]),
         # TODO: refactor this again to put all of this under update_game
         # which could return an appropriate {:error, ...} tuple when there's
         # a bad key code, with the point subtraction already calculated.
         %Player{cur_path_char_indices: cur_path_char_indices} = _player <-
           Enum.at(players, player_index),
         %PathCharIndex{} = valid_index <-
           Enum.find(cur_path_char_indices, &(char_from_course(course, &1) == key_code)),
         %Game{} = updated_game <- update_game(game, valid_index, player_index),
         updated_state <- put_in(state, [:games, game_id], updated_game) do
      notify_game_listeners(updated_game)
      {:reply, {:ok, updated_game}, updated_state}
    else
      %Game{} ->
        {:reply, {:error, "game is not running"}, state}

      _bad ->
        # subtract a point for a bad key
        # TODO: refactor to DRY it out
        %Game{players: players} = game = Kernel.get_in(state, [:games, game_id])
        %Player{points: current_points} = player = Enum.at(players, player_index)

        updated_game =
          game
          |> Map.put(
            :players,
            List.replace_at(players, player_index, Map.put(player, :points, current_points - 1))
          )

        updated_state = put_in(state, [:games, game_id], updated_game)

        {:reply, {:error, "bad key_code"}, updated_state}
    end
  end

  def handle_call({:add_player, game_id, %Player{} = player}, _from, state) do
    case Kernel.get_in(state, [:games, game_id]) do
      %Game{players: players} when length(players) >= @player_count_limit ->
        {:reply,
         {:error,
          "This game has already reached the maximum of players allowed: #{@player_count_limit}."},
         state}

      %Game{players: players} = game ->
        with %Player{} = player <- player_color(game, player),
             %Player{} = player <- player_id(player, players),
             game <- Map.put(game, :players, players ++ [player]),
             new_state <- put_in(state, [:games, game_id], game) do
          {:reply, {:ok, game, player}, new_state}
        else
          {:error, :invalid_player_color} ->
            {:reply, {:error, "invalid player color"}, state}

          {:error, :duplicate_player_id} ->
            {:reply, {:error, "duplicate player id"}, state}

          {:error, :duplicate_player_color} ->
            {:reply, {:error, "duplicate player color"}, state}
        end

      _ ->
        {:reply, {:error, "game not found"}, state}
    end
  end

  def handle_call({:remove_player, game_id, player_id}, _from, state) do
    with %Game{players: players} = game <- Kernel.get_in(state, [:games, game_id]),
         updated_players <- Enum.reject(players, &(&1.id == player_id)),
         updated_game <- Map.put(game, :players, updated_players),
         updated_state <- put_in(state, [:games, game_id], updated_game) do
      {:reply, {:ok, updated_game}, updated_state}
    else
      nil ->
        {:reply, {:error, "game not found"}, state}

      _ ->
        {:reply, {:error, "unknown error"}, state}
    end
  end

  def handle_call({:register_player_view, game_id, player_index, pid}, _from, state) do
    with %Game{players: players} = game <- Kernel.get_in(state, [:games, game_id]),
         %Player{} = player <- Enum.at(players, player_index),
         updated_player <- Map.put(player, :view_pid, pid),
         updated_players <- List.replace_at(players, player_index, updated_player),
         updated_game <- Map.put(game, :players, updated_players),
         updated_state <- put_in(state, [:games, game_id], updated_game) do
      {:reply, {:ok, updated_game}, updated_state}
    else
      nil ->
        {:reply, {:error, "game or player not found"}, state}

      _ ->
        {:reply, {:error, "unknown error"}, state}
    end
  end

  @spec reset_all() :: :ok
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  @spec state() :: map()
  def state do
    GenServer.call(__MODULE__, :state)
  end

  @spec register_player_view(binary(), integer(), pid()) :: {:ok, Game.t()} | {:error, binary()}
  def register_player_view(game_id, player_index, pid)
      when is_integer(player_index) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register_player_view, game_id, player_index, pid})
  end

  @spec new_game(Game.t()) :: binary()
  def new_game(%Game{} = game \\ %Game{}) do
    GenServer.call(__MODULE__, {:new_game, game})
  end

  @spec start_game(binary()) :: {:ok, Game.t()} | {:error, binary()}
  def start_game(game_id) when is_binary(game_id) do
    GenServer.call(__MODULE__, {:start_game, game_id})
  end

  @spec end_game(binary()) :: {:ok, Game.t()} | {:error, binary()}
  def end_game(game_id) when is_binary(game_id) do
    GenServer.call(__MODULE__, {:end_game, game_id})
  end

  @spec char_from_course(Course.t(), PathCharIndex.t()) :: char() | nil
  def char_from_course(%Course{paths: paths}, %PathCharIndex{
        path_index: path_index,
        char_index: char_index
      }) do
    with %Path{} = path <- Enum.at(paths, path_index),
         chars when is_list(chars) <- Map.get(path, :chars) do
      Enum.at(chars, char_index)
    else
      _ ->
        nil
    end
  end

  @spec advance(binary(), integer(), integer()) :: {:ok, Game.t()} | {:error, binary()}
  def advance(game_id, player_index, key_code)
      when is_binary(game_id) and is_integer(player_index) and is_integer(key_code) do
    GenServer.call(__MODULE__, {:advance_game, game_id, player_index, key_code})
  end

  @spec add_player(binary, Player.t()) :: {:ok, Game.t(), Player.t()} | {:error, binary()}
  def add_player(game_id, player \\ %Player{}) when is_binary(game_id) do
    GenServer.call(__MODULE__, {:add_player, game_id, player})
  end

  @spec remove_player(binary, binary()) :: {:ok, Game.t()} | {:error, binary()}
  def remove_player(game_id, player_id) when is_binary(game_id) and is_binary(player_id) do
    GenServer.call(__MODULE__, {:remove_player, game_id, player_id})
  end

  @spec next_chars(Course.t(), PathCharIndex.t()) :: list(PathCharIndex.t())
  def next_chars(
        %Course{paths: paths, path_connections: path_connections},
        %PathCharIndex{
          path_index: cur_path_index,
          char_index: cur_char_index
        } = cur_pci
      ) do
    %Path{chars: cur_path_chars} = Enum.at(paths, cur_path_index)

    # 1. Add the next char_index on the current path. It's always a valid next char,
    # unless we're at the end of that path.
    next_chars_list =
      case %PathCharIndex{path_index: cur_path_index, char_index: cur_char_index + 1} do
        %PathCharIndex{char_index: next_char_index} = pci
        when next_char_index < length(cur_path_chars) ->
          [pci]

        _ ->
          []
      end

    # 2. If the current char is a connection point to another path, then add that char on the other path.
    next_chars_list ++
      Enum.reduce(path_connections, [], fn
        {%PathCharIndex{} = pci_from, %PathCharIndex{} = pci_to}, acc
        when pci_from == cur_pci ->
          acc ++ [pci_to]

        _, acc ->
          acc
      end)
  end

  @type text_segment() :: {binary(), binary()}
  @spec text_segments(Game.t(), integer(), integer()) :: list(text_segment())
  def text_segments(
        %Game{players: players, course: %{paths: paths}, char_ownership: char_ownership},
        path_index,
        player_index
      )
      when is_integer(path_index) and is_integer(player_index) do
    cur_path_chars = Enum.at(paths, path_index) |> Map.get(:chars)
    cur_char_ownership = Enum.at(char_ownership, path_index)
    player_colors = Enum.map(players, & &1.color)

    player_cur_path_char_indices =
      Enum.at(players, player_index) |> Map.get(:cur_path_char_indices)

    Enum.with_index(cur_char_ownership)
    # Add a boolean to the tuple indicating whether it's a valid next-char
    |> Enum.map(
      &Tuple.append(
        &1,
        # produce true in either case:
        #   A) the current char_index on the current path is present in the current
        #      player's cur_path_char_indices.
        #   B) the
        Enum.find(
          player_cur_path_char_indices,
          fn pci ->
            pci == %PathCharIndex{path_index: path_index, char_index: elem(&1, 1)}
          end
        ) != nil
      )
    )
    |> Enum.reduce(
      %{
        cur_owner: nil,
        next_char_visited_previously: false,
        cur_segment_start: 0,
        last_index: length(cur_path_chars) - 1,
        segments: []
      },
      fn cur,
         %{
           last_index: last_index,
           cur_owner: cur_owner,
           cur_segment_start: cur_segment_start,
           segments: segments
         } = acc ->
        case cur do
          # First char index, when it is a next-char
          {owner, 0, true} ->
            %{
              acc
              | cur_owner: owner,
                cur_segment_start: 1,
                segments: [{owner, 0..0, true}]
            }

          {owner, 0, false} ->
            %{
              acc
              | cur_owner: owner,
                cur_segment_start: 0,
                segments: []
            }

          # When we're on the last index and the owner changed
          {owner, index, is_next_char} when owner != cur_owner and index == last_index ->
            %{
              acc
              | segments:
                  segments ++
                    [
                      {cur_owner, cur_segment_start..(index - 1), false},
                      {owner, index..index, is_next_char}
                    ]
            }

          # When we're on the last index, the owner is unchanged, and it is not a next char
          {_owner, index, false} when index == last_index ->
            %{
              acc
              | segments: segments ++ [{cur_owner, cur_segment_start..index, false}]
            }

          # When we're on the last index, the owner is unchanged, it is a next char,
          # and it should be broken out into its own segment
          {_owner, index, true} when index == last_index and cur_segment_start != last_index ->
            %{
              acc
              | segments:
                  segments ++
                    [
                      {cur_owner, cur_segment_start..(index - 1), false},
                      {cur_owner, index..index, true}
                    ]
            }

          # When we're somewhere in the middle, the owner has changed, it's not a next-char,
          # and it's the start of a new segment.
          {owner, index, false} when owner != cur_owner and cur_segment_start == index ->
            %{
              acc
              | cur_owner: owner,
                # This is the proper behavior when the current index is also the start of a new
                # segment and is not a next-char.
                # For example, when previous char was a next-char, and therefore would have
                # comprised its own segment and forced this char to open a new segment.
                segments: segments
            }

          # When we're somewhere in the middle, the owner has changed, it's not a next-char,
          # and it's not the start of a new segment
          {owner, index, false} when owner != cur_owner ->
            %{
              acc
              | cur_owner: owner,
                cur_segment_start: index,
                segments:
                  segments ++
                    [
                      {cur_owner,
                       cur_segment_start..if(cur_segment_start < index, do: index - 1, else: index),
                       false}
                    ]
            }

          # When we're somewhere in the middle, the owner has changed, and it is a next-char
          {owner, index, true} when owner != cur_owner ->
            %{
              acc
              | cur_owner: owner,
                # next index starts a new segment since this one can only be one char long
                cur_segment_start: index + 1,
                segments:
                  segments ++
                    [
                      {cur_owner, cur_segment_start..(index - 1), false},
                      {owner, index..index, true}
                    ]
            }

          # When we're somewhere in the middle, the owner is unchanged, but it is a next-char
          {owner, index, true} when owner == cur_owner ->
            %{
              acc
              | # next index starts a new segment since this one can only be one char long
                cur_segment_start: index + 1,
                segments:
                  segments ++
                    [
                      {cur_owner, cur_segment_start..(index - 1), false},
                      {cur_owner, index..index, true}
                    ]
            }

          # Leftover default case: When we're somewhere in the middle and the owner has not changed and it's not a next-char,
          # so there's no break in the segment--neither due to an owner change, nor due to a next-char status change.
          # Therefore, we just continue scanning forward, accumulating the segment until one of those statuses changes.
          {_owner, _index, _} ->
            acc
        end
      end
    )
    |> Map.get(:segments)
    |> Enum.map(
      &{
        cur_path_chars |> Enum.slice(elem(&1, 1)) |> List.to_string(),
        case &1 do
          {nil, _range, true} ->
            "#{unowned_class()} #{next_char_class()}"

          {nil, _range, false} ->
            unowned_class()

          {owner, _range, false} ->
            Enum.at(player_colors, owner)

          {owner, _range, true} ->
            "#{Enum.at(player_colors, owner)} #{next_char_class()}"
        end
      }
    )
  end

  @doc "Seconds until game ends. 0 if the game has ended or pending"
  @spec time_remaining(Game.t()) :: integer()
  def time_remaining(%Game{state: :ended}), do: 0
  def time_remaining(%Game{state: :pending}), do: 0

  # Handle rounding without using floats
  def time_remaining(%Game{end_time: end_time}) do
    with end_time_ms <- DateTime.to_unix(end_time, :millisecond),
         now_ms <- Util.now_unix(:millisecond),
         diff_ms <- end_time_ms - now_ms,
         floored <- Integer.floor_div(diff_ms, 1000) do
      if Integer.mod(diff_ms, 1000) >= 500 do
        floored + 1
      else
        floored
      end
    end
  end

  defp unowned_class, do: "unowned"

  defp next_char_class, do: "next-char"

  defp initialize_char_ownership(%Game{course: %Course{paths: paths}} = game) do
    game
    |> Map.put(
      :char_ownership,
      Enum.map(paths, fn %Path{chars: chars} ->
        Enum.map(chars, fn _ -> nil end)
      end)
    )
  end

  defp update_char_ownership(
         %Game{char_ownership: char_ownership} = game,
         %PathCharIndex{path_index: path_index, char_index: char_index},
         player_index
       ) do
    game
    |> Map.put(
      :char_ownership,
      char_ownership
      |> List.replace_at(
        path_index,
        Enum.at(char_ownership, path_index)
        |> List.replace_at(char_index, player_index)
      )
    )
  end

  defp initialize_starting_positions(
         %Game{
           players: players,
           course: %Course{start_positions_by_player_count: start_positions}
         } = game
       ) do
    %Game{
      game
      | players:
          Enum.with_index(players)
          |> Enum.map(fn {player, player_index} ->
            %Player{
              player
              | cur_path_char_indices: [
                  Enum.at(start_positions, length(players) - 1)
                  |> Enum.at(player_index)
                ]
            }
          end)
    }
  end

  defp player_color(%Game{}, %Player{color: color})
       when color != "" and color not in @player_colors,
       do: {:error, :invalid_player_color}

  defp player_color(%Game{players: players}, %Player{color: color} = player)
       when color != "" do
    other_players = Enum.filter(players, &(&1 != player))

    if Enum.any?(other_players, &(&1.color == color)) do
      {:error, :duplicate_player_color}
    else
      player
    end
  end

  defp player_color(%Game{players: players}, %Player{} = player) do
    with used_colors <- Enum.map(players, & &1.color),
         available_colors <-
           Enum.reject(@player_colors, fn possible_color ->
             Enum.any?(used_colors, &(&1 == possible_color))
           end),
         do: Map.put(player, :color, Enum.random(available_colors))
  end

  defp player_color(_, {:error, _} = e), do: e

  # When a player_id has already been assigned
  defp player_id(%Player{id: id} = player, players)
       when is_list(players) and id != "" do
    if Enum.any?(players, &(&1.id == id)) do
      {:error, :duplicate_player_id}
    else
      player
    end
  end

  defp player_id(%Player{} = player, _), do: Map.put(player, :id, UUID.uuid1())

  defp player_id({:error, _} = e, _), do: e

  defp initialize_players_id_color(%Game{players: players} = game) do
    initialized_players =
      players
      |> Enum.reduce_while([], fn player, acc ->
        case player_color(game, player) |> player_id(players) do
          {:error, _} = e ->
            {:halt, e}

          good ->
            {:cont, acc ++ [good]}
        end
      end)

    case initialized_players do
      {:error, e} = e ->
        e

      _ ->
        Map.put(game, :players, initialized_players)
    end
  end

  defp initialize_game(%Game{} = game) do
    game
    |> initialize_char_ownership()
    |> initialize_starting_positions()
    |> initialize_players_id_color()
    |> Map.put(:game_duration_seconds, @game_duration_seconds)
  end

  defp update_game(
         %Game{course: course, char_ownership: char_ownership, players: players} = game,
         %PathCharIndex{path_index: path_index, char_index: char_index} = valid_pci,
         current_player_index
       )
       when is_integer(current_player_index) do
    %Player{points: current_player_points} = Enum.at(players, current_player_index)

    updated_players =
      case Enum.at(char_ownership, path_index) |> Enum.at(char_index) do
        nil ->
          [{current_player_index, current_player_points, 2}]

        current_owner_player_index when current_player_index == current_owner_player_index ->
          [{current_player_index, current_player_points, 1}]

        current_owner_player_index ->
          [
            {current_owner_player_index,
             Enum.at(players, current_owner_player_index) |> Map.get(:points), -1},
            {current_player_index, current_player_points, 1}
          ]
      end
      |> Enum.reduce(players, fn {player_index, current_points, point_change}, acc ->
        List.replace_at(
          acc,
          player_index,
          Enum.at(acc, player_index)
          |> Map.put(:points, current_points + point_change)
        )
      end)

    # Update the current players cur_path_char_indices
    updated_players =
      updated_players
      |> List.replace_at(
        current_player_index,
        Enum.at(updated_players, current_player_index)
        |> Map.put(:cur_path_char_indices, next_chars(course, valid_pci))
      )

    update_char_ownership(game, valid_pci, current_player_index)
    |> Map.put(:players, updated_players)
  end

  defp notify_game_listeners(%Game{players: players} = game) do
    players
    |> Enum.each(fn
      %Player{view_pid: view_pid} when is_pid(view_pid) ->
        GenServer.cast(view_pid, {:game_updated, game})

      %Player{view_pid: nil} ->
        nil
      end)
  end
end
