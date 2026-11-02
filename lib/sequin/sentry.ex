defmodule Sequin.Sentry do
  @moduledoc false
  def init do
    env = Application.get_env(:sequin, :env)

    cond do
      System.get_env("CRASH_REPORTING_DISABLED") in ~w(true 1) ->
        Sentry.put_config(:dsn, nil)

      # Image built without a SENTRY_DSN: crash reporting is off
      env == :prod and is_nil(Application.get_env(:sentry, :dsn)) ->
        :ok

      env == :prod ->
        :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})

      true ->
        :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{})
    end
  end
end
