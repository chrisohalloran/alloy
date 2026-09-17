FROM hexpm/elixir:1.19.6-erlang-27.3.4.17-debian-bookworm-20260824-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && mix local.hex --force \
    && mix local.rebar --force

WORKDIR /workspace
