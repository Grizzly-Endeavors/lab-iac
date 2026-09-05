# Foundation PostgreSQL image — stock postgres plus the two vector-search
# extensions Immich requires (ADR-072). Built on the R730xd by the
# r730xd-postgres role; every version is passed in as a build arg from the
# role's defaults, so this file carries no pins of its own.
#
# pgvector supplies the `vector` column type. VectorChord builds its index on
# top of that type and is a shared library, so `vchord.so` must be in
# shared_preload_libraries — the role sets that in the compose command.
# `cube` and `earthdistance` already ship with the base image's contrib set.
#
# Extensions are per-database and opt-in: adding them here makes them
# available, but no existing database gains anything until someone runs
# CREATE EXTENSION in it.

# The default is only here to keep the base image name valid for linters and
# bare `docker build` — the role always passes --build-arg, and the pin that
# actually governs is postgres_version in the role's defaults.
ARG POSTGRES_VERSION=16
FROM postgres:${POSTGRES_VERSION}

# Repeat after FROM — args declared before it are out of scope in the build stage.
ARG POSTGRES_VERSION
ARG PGVECTOR_VERSION
ARG VECTORCHORD_VERSION

# pgvector comes from the PGDG apt repo the base image already configures.
# VectorChord publishes releases only as a .deb, so it is fetched directly.
# wget and ca-certificates are installed for that fetch (the base image carries
# neither, and without the CA bundle wget fails TLS verification) and are removed
# again in the same layer.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "postgresql-${POSTGRES_VERSION}-pgvector=${PGVECTOR_VERSION}" \
        ca-certificates \
        wget; \
    wget -q -O /tmp/vchord.deb \
        "https://github.com/tensorchord/VectorChord/releases/download/${VECTORCHORD_VERSION}/postgresql-${POSTGRES_VERSION}-vchord_${VECTORCHORD_VERSION}-1_amd64.deb"; \
    apt-get install -y --no-install-recommends /tmp/vchord.deb; \
    apt-get purge -y wget ca-certificates; \
    apt-get autoremove -y; \
    rm -rf /tmp/vchord.deb /var/lib/apt/lists/*
