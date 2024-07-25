#!/usr/bin/env sh

SCALE_FACTOR=0.005


cat <<EOF | docker exec --interactive berlinmod sh
echo SCALE FACTOR IS $SCALE_FACTOR \n \n
psql -U docker -d docker -c "DROP DATABASE brussels;"
psql -U docker -d docker -c "CREATE DATABASE brussels;"
psql -U docker -d brussels -c "CREATE EXTENSION mobilitydb cascade;"
psql -U docker -d brussels -c "CREATE EXTENSION pgrouting;"
psql -U docker -d brussels -c "CREATE EXTENSION hstore;"
cd /BerlinMOD
osm2pgsql -c -H localhost -U docker -d brussels brussels.osm
osm2pgrouting -h localhost -U docker -f brussels.osm --dbname brussels -c mapconfig.xml
psql -U docker -d brussels -c "\i brussels_preparedata.sql"
psql -U docker -d brussels -c "\i berlinmod_datagenerator.sql"
psql -U docker -d brussels -c "select berlinmod_generate(scaleFactor := $SCALE_FACTOR);"



EOF


# how to run the queries
# \i berlinmod_r_queries.sql
# select berlinmod_R_queries(times := 2);


# psql -U docker -d mobilitydb -c "DROP DATABASE deliveries;"
# psql -U docker -d mobilitydb -c "CREATE DATABASE deliveries;"
# psql -U docker -d deliveries -c "CREATE EXTENSION mobilitydb cascade;"
# psql -U docker -d deliveries -c "CREATE EXTENSION pgrouting;"
# psql -U docker -d deliveries -c "CREATE EXTENSION hstore;"
# osm2pgrouting -H localhost -p 5432 -U docker -W -f brussels.osm --dbname deliveries -c mapconfig_brussels.xml

# psql -U docker -d deliveries -c "\i brussels_preparedata.sql"
# psql -U docker -d deliveries -c "\i berlinmod_datagenerator.sql"
# psql -U docker -d deliveries -c "\i deliveries_datagenerator.sql"
# psql -U docker -d deliveries -c "select deliveries_generate(scaleFactor := $SCALE_FACTOR);"


# I DONT KNOW WHAT THE FUCK IS GOING ON WITH THE TRIPS PART, IS NOT EVEN LOADING
# createdb deliveries_sf0.1

# psql deliveries_sf0.1
#   create extension mobilitydb cascade;
#   create extension pgrouting;
#   create extension hstore;
#   exit


# osm2pgsql -H /tmp -P 5432 -d deliveries_sf0.1 -c -U esteban -W --proj=3857 brussels.osm

# psql deliveries_sf0.1
#   \i brussels_preparedata.sql
#   \i berlinmod_datagenerator.sql
#   \i deliveries_datagenerator.sql
#   select deliveries_datagenerator(scalefactor := 0.1);
