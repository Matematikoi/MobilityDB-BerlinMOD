FROM mobilitydb/mobilitydb:15-3.4-develop



# Install Prerequisites
RUN apt-get update
RUN apt-get install -y \
    build-essential \
    cmake \
    git \
    libproj-dev \
    g++ \
    wget \
    unzip \
    autoconf \
    autotools-dev \
    libgeos-dev \
    libpq-dev \
    libproj-dev \
    libjson-c-dev \
    protobuf-c-compiler \
    xsltproc \
    libgsl-dev \
    libgslcblas0 \
    postgresql-server-dev-15 \
    postgresql-15-pgrouting \
    osm2pgrouting \
    osm2pgsql

RUN apt-get install -y \
    postgresql-15-h3

# CMD ["/usr/local/bin/docker-entrypoint.sh","postgres"]
# COPY ./entrypoint.sh /docker-entrypoint-initdb.d/mobilitydb.sh
# RUN chmod +x /docker-entrypoint-initdb.d/mobilitydb.sh
# ENTRYPOINT ["/docker-entrypoint-initdb.d/mobilitydb.sh"]
