FROM hexpm/elixir:1.17.3-erlang-27.1-alpine-3.20.3 AS builder

WORKDIR /app

ENV MIX_ENV="prod"

RUN apk --no-cache --update add alpine-sdk gmp-dev automake libtool inotify-tools autoconf python3 file gcompat

RUN set -ex && \
    apk --update add libstdc++ curl ca-certificates gcompat

ARG CACHE_EXCHANGE_RATES_PERIOD
ARG API_V1_READ_METHODS_DISABLED
ARG DISABLE_WEBAPP
ARG API_V1_WRITE_METHODS_DISABLED
ARG CACHE_TOTAL_GAS_USAGE_COUNTER_ENABLED
ARG ADMIN_PANEL_ENABLED
ARG CACHE_ADDRESS_WITH_BALANCES_UPDATE_INTERVAL
ARG SESSION_COOKIE_DOMAIN
ARG MIXPANEL_TOKEN
ARG MIXPANEL_URL
ARG AMPLITUDE_API_KEY
ARG AMPLITUDE_URL
ARG CHAIN_TYPE
ENV CHAIN_TYPE=${CHAIN_TYPE}
ARG BRIDGED_TOKENS_ENABLED
ENV BRIDGED_TOKENS_ENABLED=${BRIDGED_TOKENS_ENABLED}
ARG MUD_INDEXER_ENABLED
ENV MUD_INDEXER_ENABLED=${MUD_INDEXER_ENABLED}
ARG SHRINK_INTERNAL_TRANSACTIONS_ENABLED
ENV SHRINK_INTERNAL_TRANSACTIONS_ENABLED=${SHRINK_INTERNAL_TRANSACTIONS_ENABLED}
ARG API_GRAPHQL_MAX_COMPLEXITY
ENV API_GRAPHQL_MAX_COMPLEXITY=${API_GRAPHQL_MAX_COMPLEXITY}

# Cache elixir deps
ADD mix.exs mix.lock ./
ADD apps/block_scout_web/mix.exs ./apps/block_scout_web/
ADD apps/explorer/mix.exs ./apps/explorer/
ADD apps/ethereum_jsonrpc/mix.exs ./apps/ethereum_jsonrpc/
ADD apps/indexer/mix.exs ./apps/indexer/

ENV MIX_HOME=/opt/mix
ENV ERL_AFLAGS="+JMsingle true"
RUN mix local.hex --force
RUN mix do deps.get, local.rebar --force, deps.compile

ADD apps ./apps
ADD config ./config
ADD rel ./rel
ADD *.exs ./

# Run backend compilation
RUN mix compile

RUN apk add --update git make 

RUN mkdir -p /opt/release \
  && mix release blockscout \
  && mv _build/${MIX_ENV}/rel/blockscout /opt/release

##############################################################
FROM hexpm/elixir:1.17.3-erlang-27.1-alpine-3.20.3

ARG RELEASE_VERSION
ENV RELEASE_VERSION=${RELEASE_VERSION}
ARG CHAIN_TYPE
ENV CHAIN_TYPE=${CHAIN_TYPE}
ARG BRIDGED_TOKENS_ENABLED
ENV BRIDGED_TOKENS_ENABLED=${BRIDGED_TOKENS_ENABLED}
ARG SHRINK_INTERNAL_TRANSACTIONS_ENABLED
ENV SHRINK_INTERNAL_TRANSACTIONS_ENABLED=${SHRINK_INTERNAL_TRANSACTIONS_ENABLED}
ARG BLOCKSCOUT_VERSION
ENV BLOCKSCOUT_VERSION=${BLOCKSCOUT_VERSION}
ARG BLOCKSCOUT_USER=blockscout
ARG BLOCKSCOUT_GROUP=blockscout
ARG BLOCKSCOUT_UID=10001
ARG BLOCKSCOUT_GID=10001

RUN apk --no-cache --update add jq curl && \
    addgroup --system --gid ${BLOCKSCOUT_GID} ${BLOCKSCOUT_GROUP} && \
    adduser --system --uid ${BLOCKSCOUT_UID} --ingroup ${BLOCKSCOUT_GROUP} --disabled-password ${BLOCKSCOUT_USER}

WORKDIR /app

COPY --from=builder --chown=${BLOCKSCOUT_USER}:${BLOCKSCOUT_GROUP} /opt/release/blockscout .
COPY --from=builder --chown=${BLOCKSCOUT_USER}:${BLOCKSCOUT_GROUP} /app/config/config_helper.exs ./config/config_helper.exs
COPY --from=builder --chown=${BLOCKSCOUT_USER}:${BLOCKSCOUT_GROUP} /app/config/config_helper.exs /app/releases/${RELEASE_VERSION}/config_helper.exs
COPY --from=builder --chown=${BLOCKSCOUT_USER}:${BLOCKSCOUT_GROUP} /app/config/assets/precompiles-arbitrum.json ./config/assets/precompiles-arbitrum.json

RUN chown -R ${BLOCKSCOUT_USER}:${BLOCKSCOUT_GROUP} /app

USER ${BLOCKSCOUT_USER}:${BLOCKSCOUT_GROUP}
