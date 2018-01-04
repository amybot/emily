defmodule Emily.Bucket do
  alias Emily.Util
  alias Lace.Redis

  def create_bucket(route, remaining, reset_time, latency) do
    Redis.q ["SET", "route:#{route}:remaining", remaining]
    Redis.q ["SET", "route:#{route}:reset_time", reset_time]
    Redis.q ["SET", "route:#{route}:latency", latency]
  end

  defp str_to_int(str) do
    unless str == :undefined do
      if is_binary str do
        str |> String.to_integer
      else
        str
      end
    else
      :undefined
    end
  end

  defp get_bucket(route) do
    {:ok, remaining} = Redis.q ["GET", "route:#{route}:remaining"]
    {:ok, reset_time} = Redis.q ["GET", "route:#{route}:reset_time"]
    {:ok, latency} = Redis.q ["GET", "route:#{route}:latency"]

    {route, str_to_int(remaining), str_to_int(reset_time), str_to_int(latency)}
  end

  def lookup_bucket(route) do
    route_time = get_bucket route
    global_time = get_bucket "GLOBAL"
    # If there's a global ratelimit, then respect it. Otherwise, per-route 
    # ratelimits.
    case global_time do
      {"GLOBAL", :undefined, :undefined, :undefined} -> [route_time]
      _ -> [global_time]
    end
  end

  def update_bucket(route, remaining) do
    Redis.q ["SET", "route:#{route}:remaining", remaining]
  end

  def delete_bucket(route) do
    Redis.q ["DEL", "route:#{route}:remaining"]
    Redis.q ["DEL", "route:#{route}:reset_time"]
    Redis.q ["DEL", "route:#{route}:latency"]
  end

  def get_ratelimit_timeout(route) do
    case lookup_bucket(route) do
      [] ->
        # No ratelimit data at all
        :none
      [{route, remaining, reset_time, latency}] when remaining <= 0 ->
        update_bucket(route, remaining - 1)
        wait_time = reset_time - Util.now + latency
        if wait_time <= 0 do
          # Wait time over, delete the bucket and send
          delete_bucket(route)
          nil
        else
          # Gotta wait :<
          wait_time
        end
      [{route, :undefined, _reset_time, _latency}] ->
        nil
      [{route, remaining, _reset_time, _latency}] ->
        # We have requests remaining, might as well send
        update_bucket(route, remaining - 1)
        nil
    end
  end
end
