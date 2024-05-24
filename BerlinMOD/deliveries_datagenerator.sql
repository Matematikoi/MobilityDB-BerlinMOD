/*-----------------------------------------------------------------------------
-- Deliveries Data Generator
-------------------------------------------------------------------------------
This file is part of MobilityDB.
Copyright (C) 2024, Esteban Zimanyi, Mahmoud Sakr,
  Universite Libre de Bruxelles.

The functions defined in this file use MobilityDB to generate data
corresponding to a delivery service as specified in
https://www.mdpi.com/2220-9964/8/4/170/htm
These functions call other functions defined in the file
berlinmod_datagenerator.sql located in the same directory as the
current file.

The generator needs the underlying road network topology. The file
brussels_preparedata.sql in the same directory can be used to create the
road network for Brussels constructed from OSM data by osm2pgrouting.
Alternatively, an optimized version of the graph can be constructed with the
file brussels_creategraph.sql that creates the graph from OSM data using SQL.

You can change parameters in the various functions of this file.
Usually, changing the master parameter 'P_SCALE_FACTOR' should do it.
But you also might be interested in changing parameters for the
random number generator, experiment with non-standard scaling
patterns or modify the sampling of positions.

The database must contain the following input relations:

*  Nodes and Edges are the tables defining the road network graph.
  These tables are typically obtained by osm2pgrouting from OSM data.
  The description of these tables is given in the file
  berlinmod_datagenerator.sql

The generated data is saved into the database in which the
functions are executed using the following tables

*  Warehouses(warehouseId int primary key, node bigint, geom geometry(Point))
*  Vehicles(vehId int primary key, licence text, vehType text, brand text,
    warehouse int)
*  Trips(vehId int, startDate date, seqNo int, source bigint, target bigint)
    primary key (vehId, StartDate, seqNo)
*  Destinations(id serial, source bigint, target bigint)
*  Paths(seqNo int, path_seq int, start_vid bigint, end_vid bigint,
    node bigint, edge bigint, geom geometry, speed float, category int);
*  Segments(deliveryId int, seqNo int, source bigint, target bigint,
    trip tgeompoint, trajectory geometry, sourceGeom geometry)
    primary key (deliveryId, seqNo)
*  Deliveries(deliveryId int primary key, vehId int, startDate date,
    noCustomers int, trip tgeompoint, trajectory geometry)
*  Points(id int primary key, geom geometry)
*  Regions(id int primary key, geom geometry)
*  Instants(id int primary key, instant timestamptz)
*  Periods(id int primary key, period tstzspan)

-----------------------------------------------------------------------------*/

-- Type combining the elements needed to define a path in the graph

DROP TYPE IF EXISTS step CASCADE;
CREATE TYPE step as (linestring geometry, maxspeed float, category int);

-- Generate the data for a given number vehicles and days starting at a day.
-- The last two arguments correspond to the parameters P_PATH_MODE and
-- P_DISTURB_DATA

DROP FUNCTION IF EXISTS deliveries_createDeliveries;
CREATE FUNCTION deliveries_createDeliveries(noVehicles int, noDays int,
  startDay Date, disturbData boolean, messages text)
RETURNS void LANGUAGE plpgsql STRICT AS $$
DECLARE
  -- Loops over the days for which we generate the data
  aDay date;
  -- 0 (Sunday) to 6 (Saturday)
  weekday int;
  -- Current timestamp
  t timestamptz;
  -- Identifier of the deliveries
  delivId int;
  -- Number of segments in a delivery (number of destinations + 1)
  noSegments int;
  -- Source and target nodes of a delivery segment
  sourceNode bigint; targetNode bigint;
  -- Path betwen start and end nodes
  path step[];
  -- Segment trip obtained from a path
  trip tgeompoint;
  -- All segment trips of a delivery
  alltrips tgeompoint[] = '{}';
  -- Geometry of the source noDeliveries
  sourceGeom geometry;
  -- Start time of a segment
  startTime timestamptz;
  -- Time of the trip to a customer
  tripTime interval;
  -- Time servicing a customer
  deliveryTime interval;
  -- Loop variables
  i int; j int; k int;
  -- Number of vehicles for showing heartbeat messages when message is 'minimal'
  P_DELIVERIES_NO_VEHICLES int = 50;
BEGIN
  RAISE INFO 'Creating the Deliveries and Segments tables';
  DROP TABLE IF EXISTS Deliveries;
  CREATE TABLE Deliveries(deliveryId int PRIMARY KEY, vehId int, startDate date,
    noCustomers int, trip tgeompoint, trajectory geometry);
  DROP TABLE IF EXISTS Segments;
  CREATE TABLE Segments(deliveryId int, seqNo int, source bigint,
    target bigint, trip tgeompoint,
    -- These columns are used for visualization purposes
    trajectory geometry, sourceGeom geometry,
    PRIMARY KEY (deliveryId, seqNo));
  delivId = 1;
  aDay = startDay;
  FOR i IN 1..noDays LOOP
    SELECT date_part('dow', aDay) into weekday;
    IF messages = 'minimal' OR messages = 'medium' OR messages = 'verbose' THEN
      RAISE INFO '-- Date %', aDay;
    END IF;
    -- 6: saturday, 0: sunday
    IF weekday <> 0 THEN
      <<vehicles_loop>>
      FOR j IN 1..noVehicles LOOP
        IF messages = 'minimal' AND j % P_DELIVERIES_NO_VEHICLES = 1 THEN
          RAISE INFO '  -- Vehicles % to %', j,
            LEAST(j + P_DELIVERIES_NO_VEHICLES - 1, noVehicles);
        END IF;
        IF messages = 'medium' OR messages = 'verbose' THEN
          RAISE INFO '  -- Vehicle %', j;
        END IF;
        -- Start delivery
        t = aDay + time '07:00:00' + createPauseN(120);
        IF messages = 'medium' OR messages = 'verbose' THEN
          RAISE INFO '    Delivery starting at %', t;
        END IF;
        -- Get the number of segments (number of destinations + 1)
        SELECT COUNT(*) INTO noSegments
        FROM Trips
        WHERE vehId = j AND startDate = aDay;
        <<segments_loop>>
        FOR k IN 1..noSegments LOOP
          -- Get the source and destination nodes of the segment
          SELECT source, target INTO sourceNode, targetNode
          FROM Trips
          WHERE vehId = j AND startDate = aDay AND seqNo = k;
          -- Get the path
          SELECT array_agg((geom, speed, category) ORDER BY path_seq) INTO path
          FROM Paths P
          WHERE start_vid = sourceNode AND end_vid = targetNode AND edge > 0;
          -- In exceptional circumstances, depending on the input graph, it may
          -- be the case that pgrouting does not find a connecting path between
          -- two nodes. Instead of stopping the generation process, the error
          -- is reported, the trip for the vehicle and the day is ignored, and
          -- the generation process is continued.
          IF path IS NULL THEN
            RAISE INFO 'ERROR: The path of a trip cannot be NULL. ';
            RAISE INFO '       Source node: %, target node: %, k: %, noSegments: %',
              sourceNode, targetNode, k, noSegments;
            RAISE INFO '       The trip of vehicle % for day % is ignored', j, aDay;
            DELETE FROM Segments where deliveryId = delivId;
            alltrips = '{}';
            delivId = delivId + 1;
            CONTINUE vehicles_loop;
          END IF;
          startTime = t;
          trip = create_trip(path, t, disturbData, messages);
          IF trip IS NULL THEN
            RAISE INFO 'ERROR: A trip cannot be NULL';
            RAISE INFO '  The trip of vehicle % for day % is ignored', j, aDay;
            DELETE FROM Segments where deliveryId = delivId;
            alltrips = '{}';
            delivId = delivId + 1;
            CONTINUE vehicles_loop;
          END IF;
          t = endTimestamp(trip);
          tripTime = t - startTime;
          IF messages = 'medium' OR messages = 'verbose' THEN
            RAISE INFO '      Trip to destination % started at % and lasted %',
              k, startTime, tripTime;
          END IF;
          IF k < noSegments THEN
            -- Add a delivery time in [10, 60] min using a bounded Gaussian distribution
            deliveryTime = random_boundedgauss(10, 60) * interval '1 min';
            IF messages = 'medium' OR messages = 'verbose' THEN
              RAISE INFO '      Delivery lasted %', deliveryTime;
            END IF;
            t = t + deliveryTime;
            trip = appendInstant(trip, tgeompoint(endValue(trip), t));
          END IF;
          alltrips = alltrips || trip;
          SELECT geom INTO sourceGeom FROM Nodes WHERE id = sourceNode;
          INSERT INTO Segments(deliveryId, seqNo, source, target, trip, trajectory, sourceGeom)
            VALUES (delivId, k, sourceNode, targetNode, trip, trajectory(trip), sourceGeom);
        END LOOP;
        trip = merge(alltrips);
        INSERT INTO Deliveries(deliveryId, vehId, startDate, noCustomers, trip, trajectory)
          VALUES (delivId, j, aDay, noSegments - 1, trip, trajectory(trip));
        IF messages = 'medium' OR messages = 'verbose' THEN
          RAISE INFO '    Delivery ended at %', t;
        END IF;
        delivId = delivId + 1;
        alltrips = '{}';
      END LOOP;
    ELSE
      IF messages = 'minimal' OR messages = 'medium' OR messages = 'verbose' THEN
        RAISE INFO '  No deliveries on Sunday';
      END IF;
    END IF;
    aDay = aDay + interval '1 day';
  END LOOP;
  -- Build indexes to speed up processing
  CREATE INDEX Segments_spgist_idx ON Segments USING spgist(trip);
  CREATE INDEX Deliveries_spgist_idx ON Deliveries USING spgist(trip);
  RETURN;
END; $$;

/*
SELECT deliveries_createDeliveries(2, 2, '2020-06-01', false, 'minimal');
*/

-------------------------------------------------------------------------------
-- Selects the next destination node for a delivery
-------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS deliveries_selectDestNode;
CREATE FUNCTION deliveries_selectDestNode(vehicId int, noNodes int,
  prevNodes bigint[])
RETURNS bigint AS $$
DECLARE
  -- Random sequence number
  seqNo int;
  -- Result of the function
  result bigint;
BEGIN
  WHILE true LOOP
    result = random_int(1, noNodes);
    IF result != ALL(prevNodes) THEN
      RETURN result;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql STRICT;

-------------------------------------------------------------------------------
-- Main Function
-------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS deliveries_datagenerator;
CREATE FUNCTION deliveries_datagenerator(scaleFactor float DEFAULT NULL,
  noWarehouses int DEFAULT NULL, noVehicles int DEFAULT NULL,
  noDays int DEFAULT NULL, startDay date DEFAULT NULL,
  pathMode text DEFAULT NULL, disturbData boolean DEFAULT NULL,
  messages text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE

  ----------------------------------------------------------------------
  -- Primary parameters, which are optional arguments of the function
  ----------------------------------------------------------------------

  -- Scale factor
  -- Set value to 1.0 or bigger for a full-scaled benchmark
  P_SCALE_FACTOR float = 0.005;

  -- By default, the scale factor determines the number of warehouses, the
  -- number of vehicles and the number of days they are observed as follows
  --    noWarehouses int = round((100 * SCALEFCARS)::numeric, 0)::int;
  --    noVehicles int = round((2000 * sqrt(P_SCALE_FACTOR))::numeric, 0)::int;
  --    noDays int = round((sqrt(P_SCALE_FACTOR) * 28)::numeric, 0)::int;
  -- For example, for P_SCALE_FACTOR = 1.0 these values will be
  --    noWarehouses = 100
  --    noVehicles = 2000
  --    noDays int = 28
  -- Alternatively, you can manually set these parameters to arbitrary
  -- values using the optional arguments in the function call.

  -- The day the observation starts ===
  -- default: P_START_DAY = monday 06/01/2020)
  P_START_DAY date = '2020-06-01';

  -- Method for selecting a path between a start and end nodes.
  -- Possible values are 'Fastest Path' (default) and 'Shortest Path'
  P_PATH_MODE text = 'Fastest Path';

  -- Choose imprecise data generation. Possible values are
  -- FALSE (no imprecision, default) and TRUE (disturbed data)
  P_DISTURB_DATA boolean = FALSE;

  -------------------------------------------------------------------------
  --  Secondary Parameters
  -------------------------------------------------------------------------

  -- Seed for the random generator used to ensure deterministic results
  P_RANDOM_SEED float = 0.5;

  -- Size for sample relations
  P_SAMPLE_SIZE int = 100;

  -- Number of paths sent in a batch to pgRouting
  P_PGROUTING_BATCH_SIZE int = 1e5;

  -- Minimum length in milliseconds of a pause, used to distinguish subsequent
  -- trips. Default 5 minutes
  P_MINPAUSE interval = 5 * interval '1 min';

  -- Velocity below which a vehicle is considered to be static
  -- Default: 0.04166666666666666667 (=1.0 m/24.0 h = 1 m/day)
  P_MINVELOCITY float = 0.04166666666666666667;

  -- Duration in milliseconds between two subsequent GPS-observations
  -- Default: 2 seconds
  P_GPSINTERVAL interval = 2 * interval '1 ms';

  -- Quantity of messages shown describing the generation process.
  -- Possible values are 'verbose', 'medium', 'minimal', and 'none'.
  -- Choose 'none' to only show the main steps of the process. However,
  -- for large scale factors, no message will be issued while executing steps
  -- taking long time and it may seems that the generated is blocked.
  -- You may change to 'minimal' to be sure that the generator is running.
  P_MESSAGES text = 'none';

  -- Constants defining the values of the Vehicles table
  VEHICLETYPES text[] = '{"van", "truck", "pickup"}';
  NOVEHICLETYPES int = array_length(VEHICLETYPES, 1);
  VEHICLEBRANDS text[] = '{"RAM", "GMC", "Ford", "Chevrolet",
    "Volkswagen", "Mercedes-Benz", "Citroën", "Renault", "Peugeot",
    "Fiat", "Nissan", "Toyota", "Daihatsu", "Hyundai", "Honda"}';
  NOVEHICLEBRANDS int = array_length(VEHICLEBRANDS, 1);

  ----------------------------------------------------------------------
  --  Variables
  ----------------------------------------------------------------------
  -- Loop variable
  i int;
  -- Number of nodes in the graph
  noNodes int;
  -- Number of paths and number of calls to pgRouting
  noPaths int; noCalls int;
  -- Number of segments and deliveries generated
  noSegments int; noDeliveries int;
  -- Warehouse node
  warehouseNode bigint;
  -- Node identifiers of a delivery segment
  sourceNode bigint; targetNode bigint;
  -- Day for which we generate data
  day date;
  -- Start and end time of the execution
  startTime timestamptz; endTime timestamptz;
  -- Start and end time of the batch call to pgRouting
  startPgr timestamptz; endPgr timestamptz;
  -- Queries sent to pgrouting for choosing the path according to P_PATH_MODE
  -- and the number of records defined by LIMIT/OFFSET
  query1_pgr text; query2_pgr text;
  -- Random number of destinations (between 1 and 3)
  noDest int;
  -- Previous nodes of the current delivery
  prevNodes bigint[];
  -- String to generate the trace message
  str text;
  -- Attributes of table Vehicle
  licence text; type text; brand text; warehouse int;
BEGIN
  -------------------------------------------------------------------------
  --  Initialize parameters and variables
  -------------------------------------------------------------------------

  -- Set the P_RANDOM_SEED so that the random function will return a repeatable
  -- sequence of random numbers that is derived from the P_RANDOM_SEED.
  PERFORM setseed(P_RANDOM_SEED);

  -- Setting the parameters of the generation
  IF scaleFactor IS NULL THEN
    scaleFactor = P_SCALE_FACTOR;
  END IF;
  IF noWarehouses IS NULL THEN
    noWarehouses = round((100 * sqrt(scaleFactor))::numeric, 0)::int;
  END IF;
  IF noVehicles IS NULL THEN
    noVehicles = round((2000 * sqrt(scaleFactor))::numeric, 0)::int;
  END IF;
  IF noDays IS NULL THEN
    noDays = round((sqrt(scaleFactor) * 28)::numeric, 0)::int + 2;
  END IF;
  IF startDay IS NULL THEN
    startDay = P_START_DAY;
  END IF;
  IF pathMode IS NULL THEN
    pathMode = P_PATH_MODE;
  END IF;
  IF disturbData IS NULL THEN
    disturbData = P_DISTURB_DATA;
  END IF;
  IF messages IS NULL THEN
    messages = P_MESSAGES;
  END IF;

  -- Set the seed so that the random function will return a repeatable
  -- sequence of random numbers that is derived from the P_RANDOM_SEED.
  PERFORM setseed(P_RANDOM_SEED);

  -- Get the number of nodes
  SELECT COUNT(*) INTO noNodes FROM Nodes;

  RAISE INFO '-----------------------------------------------------------------------';
  RAISE INFO 'Starting deliveries generation with scale factor %', scaleFactor;
  RAISE INFO '-----------------------------------------------------------------------';
  RAISE INFO 'Parameters:';
  RAISE INFO '------------';
  RAISE INFO 'No. of warehouses = %, No. of vehicles = %, No. of days = %',
    noWarehouses, noVehicles, noDays;
  RAISE INFO 'Start day = %, Path mode = %, Disturb data = %',
    startDay, pathMode, disturbData;
  SELECT clock_timestamp() INTO startTime;
  RAISE INFO 'Execution started at %', startTime;
  RAISE INFO '----------------------------------------------------------------------';

  -------------------------------------------------------------------------
  --  Creating the base data
  -------------------------------------------------------------------------

  -- Create a table accumulating all pairs (source, target) that will be
  -- sent to pgRouting in a single call. We DO NOT test whether we are
  -- inserting duplicates in the table, the query sent to the pgr_dijkstra
  -- function MUST use 'SELECT DISTINCT ...'

  RAISE INFO 'Creating the Warehouses table';
  DROP TABLE IF EXISTS Warehouses;
  CREATE TABLE Warehouses(warehouseId int PRIMARY KEY, node bigint,
    geom geometry(Point));

  FOR i IN 1..noWarehouses LOOP
    -- Create a warehouse located at that a random node
    INSERT INTO Warehouses(warehouseId, node, geom)
    SELECT i, id, geom
    FROM Nodes N
    ORDER BY id LIMIT 1 OFFSET random_int(1, noNodes) - 1;
  END LOOP;

  -- Create a relation with all vehicles and the associated warehouse.
  -- Warehouses are associated to vehicles in a round-robin way.

  RAISE INFO 'Creating the Vehicle table';

  DROP TABLE IF EXISTS Vehicles;
  CREATE TABLE Vehicles(vehId int PRIMARY KEY, licence text, vehType text,
    brand text, warehouse int);

  FOR i IN 1..noVehicles LOOP
    licence = berlinmod_createLicence(i);
    type = VEHICLETYPES[random_int(1, NOVEHICLETYPES)];
    brand = VEHICLEBRANDS[random_int(1, NOVEHICLEBRANDS)];
    warehouse = 1 + ((i - 1) % noWarehouses);
    INSERT INTO Vehicles VALUES (i, licence, type, brand, warehouse);
  END LOOP;

  -- Build indexes to speed up processing
  CREATE UNIQUE INDEX Vehicles_id_idx ON Vehicles USING BTREE(vehId);

  -------------------------------------------------------------------------
  -- Create auxiliary benchmarking data
  -- The number of rows these tables is determined by P_SAMPLE_SIZE
  -------------------------------------------------------------------------

  RAISE INFO 'Creating the QueryPoints and QueryRegions tables';

  DROP TABLE IF EXISTS QueryPoints;
  CREATE TABLE QueryPoints(id int PRIMARY KEY, geom geometry(Point));
  INSERT INTO QueryPoints
  WITH Temp AS (
    SELECT id, random_int(1, noNodes) AS node
    FROM generate_series(1, P_SAMPLE_SIZE) id
  )
  SELECT T.id, N.geom
  FROM Temp T, Nodes N
  WHERE T.node = N.id;

  -- Random regions

  DROP TABLE IF EXISTS QueryRegions;
  CREATE TABLE QueryRegions(id int PRIMARY KEY, geom geometry(Polygon));
  INSERT INTO QueryRegions
  WITH Temp AS (
    SELECT id, random_int(1, noNodes) AS node
    FROM generate_series(1, P_SAMPLE_SIZE) id
  )
  SELECT T.id, ST_Buffer(N.geom, random_int(1, 997) + 3.0, random_int(0, 25)) AS geom
  FROM Temp T, Nodes N
  WHERE T.node = N.id;

  -- Random instants

  RAISE INFO 'Creating the QueryInstants and QueryPeriods tables';

  DROP TABLE IF EXISTS QueryInstants;
  CREATE TABLE QueryInstants(id int PRIMARY KEY, instant timestamptz);
  INSERT INTO QueryInstants
  SELECT id, startDay + (random() * noDays) * interval '1 day' AS instant
  FROM generate_series(1, P_SAMPLE_SIZE) id;

  -- Random periods

  DROP TABLE IF EXISTS QueryPeriods;
  CREATE TABLE QueryPeriods(id int PRIMARY KEY, period tstzspan);
  INSERT INTO QueryPeriods
  WITH Instants AS (
    SELECT id, startDay + (random() * noDays) * interval '1 day' AS instant
    FROM generate_series(1, P_SAMPLE_SIZE) id
  )
  SELECT id, span(instant, instant + abs(random_gauss()) * interval '1 day',
    true, true) AS period
  FROM Instants;

  -------------------------------------------------------------------------
  -- Generate the deliveries
  -------------------------------------------------------------------------

  RAISE INFO 'Creating the Trips and Destinations tables';

  DROP TABLE IF EXISTS Trips;
  CREATE TABLE Trips(vehId int, startDate date, seqNo int,
    source bigint, target bigint,
    PRIMARY KEY (vehId, startDate, seqNo));
  DROP TABLE IF EXISTS Destinations;
  CREATE TABLE Destinations(id serial PRIMARY KEY, source bigint, target bigint);
  -- Loop for every vehicle
  FOR i IN 1..noVehicles LOOP
    IF messages = 'verbose' THEN
      RAISE INFO '-- Vehicle %', i;
    END IF;
    -- Get the warehouse node
    SELECT W.node INTO warehouseNode
    FROM Vehicles V, Warehouses W
    WHERE V.vehId = i AND V.warehouse = W.warehouseId;
    day = startDay;
    -- Loop for every generation day
    FOR j IN 1..noDays LOOP
      IF messages = 'verbose' THEN
        RAISE INFO '  -- Day %', day;
      END IF;
      -- Generate deliveries excepted on Sunday
      IF date_part('dow', day) <> 0 THEN
        -- Select a number of destinations between 3 and 7
        SELECT random_int(3, 7) INTO noDest;
        IF messages = 'verbose' THEN
          RAISE INFO '    Number of destinations: %', noDest;
        END IF;
        sourceNode = warehouseNode;
        prevNodes = '{}';
        prevNodes = prevNodes || warehouseNode;
        FOR k IN 1..noDest + 1 LOOP
          IF k <= noDest THEN
            targetNode = deliveries_selectDestNode(i, noNodes, prevNodes);
            prevNodes = prevNodes || targetNode;
          ELSE
            targetNode = warehouseNode;
          END IF;
          IF sourceNode IS NULL THEN
            RAISE EXCEPTION '    Destination node cannot be NULL';
          END IF;
          IF targetNode IS NULL THEN
            RAISE EXCEPTION '    Destination node cannot be NULL';
          END IF;
          IF sourceNode = targetNode THEN
            RAISE EXCEPTION '    Source and destination nodes must be different, node: %', sourceNode;
          END IF;
          IF messages = 'verbose' THEN
            RAISE INFO '    Delivery segment from % to %', sourceNode, targetNode;
          END IF;
          -- Keep the start and end nodes of each segment
          INSERT INTO Trips VALUES (i, day, k, sourceNode, targetNode);
          INSERT INTO Destinations(source, target) VALUES (sourceNode, targetNode);
          sourceNode = targetNode;
        END LOOP;
      ELSE
        IF messages = 'verbose' THEN
          RAISE INFO 'No delivery on Sunday';
        END IF;
      END IF;
      day = day + interval '1 day';
    END LOOP;
  END LOOP;

  -------------------------------------------------------------------------
  -- Call pgRouting to generate the paths
  -------------------------------------------------------------------------

  RAISE INFO 'Creating the Paths table';
  DROP TABLE IF EXISTS Paths;
  CREATE TABLE Paths(
    -- The following attributes are generated by pgRouting
    start_vid bigint, end_vid bigint, path_seq int, node bigint, edge bigint,
    -- The following attributes are filled in the subsequent update
    geom geometry NOT NULL, speed float NOT NULL, category int NOT NULL,
    PRIMARY KEY (start_vid, end_vid, path_seq));

  -- Select query sent to pgRouting
  IF pathMode = 'Fastest Path' THEN
    query1_pgr = 'SELECT id, sourcenode as source, targetnode as target, cost_s AS cost, reverse_cost_s as reverse_cost FROM edges';
  ELSE
    query1_pgr = 'SELECT id, sourcenode as source, targetnode as target, length_m AS cost, length_m * sign(reverse_cost_s) as reverse_cost FROM edges';
  END IF;
  -- Get the total number of paths and number of calls to pgRouting
  SELECT COUNT(*) INTO noPaths FROM (SELECT DISTINCT source, target FROM Destinations) AS T;
  noCalls = ceiling(noPaths / P_PGROUTING_BATCH_SIZE::float);
  IF messages = 'minimal' OR messages = 'medium' OR messages = 'verbose' THEN
    IF noCalls = 1 THEN
      RAISE INFO '  Call to pgRouting to compute % paths', noPaths;
    ELSE
      RAISE INFO '  Call to pgRouting to compute % paths in % calls of % (source, target) couples each',
        noPaths, noCalls, P_PGROUTING_BATCH_SIZE;
    END IF;
  END IF;

  startPgr = clock_timestamp();
  FOR i IN 1..noCalls LOOP
    query2_pgr = format('SELECT DISTINCT source, target FROM Destinations ORDER BY source, target LIMIT %s OFFSET %s',
      P_PGROUTING_BATCH_SIZE, (i - 1) * P_PGROUTING_BATCH_SIZE);
    IF messages = 'medium' OR messages = 'verbose' THEN
      IF noCalls = 1 THEN
        RAISE INFO '  Call started at %', clock_timestamp();
      ELSE
        RAISE INFO '  Call number % started at %', i, clock_timestamp();
      END IF;
    END IF;
    INSERT INTO Paths(start_vid, end_vid, path_seq, node, edge, geom, speed, category)
    WITH Temp AS (
      SELECT start_vid, end_vid, path_seq, node, edge
      FROM pgr_dijkstra(query1_pgr, query2_pgr, true)
      WHERE edge > 0
    )
    SELECT start_vid, end_vid, path_seq, node, edge,
      -- adjusting directionality
      CASE
        WHEN T.node = E.sourceNode THEN E.geom
        ELSE ST_Reverse(E.geom)
      END AS geom, E.maxspeed_forward AS speed,
      berlinmod_roadCategory(E.tag_id) AS category
    FROM Temp T, Edges E
    WHERE E.id = T.edge;
    IF messages = 'medium' OR messages = 'verbose' THEN
      IF noCalls = 1 THEN
        RAISE INFO '  Call ended at %', clock_timestamp();
      ELSE
        RAISE INFO '  Call number % ended at %', i, clock_timestamp();
      END IF;
    END IF;
  END LOOP;
  endPgr = clock_timestamp();

  -- Build index to speed up processing
  CREATE INDEX Paths_start_vid_end_vid_idx ON Paths
    USING BTREE(start_vid, end_vid);

  -------------------------------------------------------------------------
  -- Generate the deliveries
  -------------------------------------------------------------------------

  PERFORM deliveries_createDeliveries(noVehicles, noDays, startDay,
    disturbData, messages);

  -- Get the number of deliveries generated
  SELECT COUNT(*) INTO noSegments FROM Segments;
  SELECT COUNT(*) INTO noDeliveries FROM Deliveries;

  SELECT clock_timestamp() INTO endTime;
  IF messages = 'medium' OR messages = 'verbose' THEN
    RAISE INFO '-----------------------------------------------------------------------';
    RAISE INFO 'Deliveries generation with scale factor %', scaleFactor;
    RAISE INFO '-----------------------------------------------------------------------';
    RAISE INFO 'Parameters:';
    RAISE INFO '------------';
    RAISE INFO 'No. of warehouses = %, No. of vehicles = %, No. of days = %',
      noWarehouses, noVehicles, noDays;
    RAISE INFO 'Start day = %, Path mode = %, Disturb data = %',
      startDay, pathMode, disturbData;
  END IF;
  RAISE INFO '----------------------------------------------------------------------';
  RAISE INFO 'Execution started at %', startTime;
  RAISE INFO 'Execution finished at %', endTime;
  RAISE INFO 'Execution time %', endTime - startTime;
  RAISE INFO 'Call to pgRouting with % paths lasted %',
    noPaths, endPgr - startPgr;
  RAISE INFO 'Number of deliveries generated %', noDeliveries;
  RAISE INFO 'Number of segments generated %', noSegments;
  RAISE INFO '----------------------------------------------------------------------';

  -------------------------------------------------------------------------------------------------

  return 'THE END';
END; $$;

/*
select deliveries_generate();
*/

----------------------------------------------------------------------
-- THE END
----------------------------------------------------------------------
