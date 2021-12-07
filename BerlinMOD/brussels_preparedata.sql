-------------------------------------------------------------------------------
-- Getting OSM data and importing it in PostgreSQL
-------------------------------------------------------------------------------
/* To be done on a terminal

CITY="brussels"
BBOX="4.22,50.75,4.5,50.92"
wget --progress=dot:mega -O "$CITY.osm" "http://www.overpass-api.de/api/xapi?*[bbox=${BBOX}][@meta]"

-- To reduce the size of the OSM file
sed -r "s/version=\"[0-9]+\" timestamp=\"[^\"]+\" changeset=\"[0-9]+\" uid=\"[0-9]+\" user=\"[^\"]+\"//g" brussels.osm -i.org

-- The resulting data is by default in Spherical Mercator (SRID 3857) so that
- it can be displayed directly, e.g. in QGIS
osm2pgsql --create --database "$CITY" --host localhost "$CITY.osm"

-- IT IS NECESSARY TO SETUP the configuration file mapconfig_brussels.xml,
-- e.g., starting from the default file mapconfig_for_cars.xml provided by
-- osm2pgrouting. An example of this file can be found in this directory.
-- The resulting data are in WGS84 (SRID 4326)
osm2pgrouting -U username -f "$CITY.osm" --dbname "$CITY" -c mapconfig_brussels.xml
*/

-- We need to convert the resulting data in Spherical Mercator (SRID = 3857)
-- We create two tables for that

DROP TABLE IF EXISTS Edges;
CREATE TABLE Edges AS
SELECT gid AS edgeId, osm_id, tag_id, length_m, source AS sourceNode, target AS targetNode,
  source_osm, target_osm, cost_s, reverse_cost_s, one_way, maxspeed_forward,
  maxspeed_backward, priority, ST_Transform(the_geom, 3857) AS geom
FROM ways;

-- The nodes table should contain ONLY the vertices that belong to the largest
-- connected component in the underlying map. Like this, we guarantee that
-- there will be a non-NULL shortest path between any two nodes.
DROP TABLE IF EXISTS Nodes;
CREATE TABLE Nodes AS
WITH Components AS (
  SELECT * FROM pgr_strongComponents(
    'SELECT EdgeId AS id, sourceNode AS source, targetNode AS target, length_m AS cost, '
    'length_m * sign(reverse_cost_s) AS reverse_cost FROM Edges') ),
LargestComponent AS (
  SELECT component, count(*) FROM Components
  GROUP BY component ORDER BY count(*) DESC LIMIT 1),
Connected AS (
  SELECT id, osm_id, the_geom AS geom
  FROM ways_vertices_pgr W, LargestComponent L, Components C
  WHERE W.id = C.node AND C.component = L.component
)
SELECT ROW_NUMBER() OVER () AS NodeId, osm_id, ST_Transform(geom, 3857) AS geom
FROM Connected;

CREATE UNIQUE INDEX Nodes_NodeId_idx ON Nodes USING BTREE(NodeId);
CREATE INDEX Nodes_osm_id_idx ON Nodes USING BTREE(osm_id);
CREATE INDEX Nodes_geom_idx ON NODES USING GiST(geom);

UPDATE Edges E SET
sourceNode = (SELECT NodeId FROM Nodes N WHERE N.osm_id = E.source_osm),
targetNode = (SELECT NodeId FROM Nodes N WHERE N.osm_id = E.target_osm);

-- Delete the edges whose source or target node has been removed
DELETE FROM Edges WHERE sourceNode IS NULL OR targetNode IS NULL;

CREATE UNIQUE INDEX Edges_EdgeId_idx ON Edges USING BTREE(edgeId);
CREATE INDEX Edges_geom_index ON Edges USING GiST(geom);

/*
SELECT count(*) FROM Edges;
-- 80831
SELECT count(*) FROM Nodes;
-- 65052
*/

-------------------------------------------------------------------------------
-- Get municipalities data to define home and work regions
-------------------------------------------------------------------------------

-- Brussels' municipalities data from the following sources
-- https://en.wikipedia.org/wiki/List_of_municipalities_of_the_Brussels-Capital_Region
-- http://ibsa.brussels/themes/economie

DROP TABLE IF EXISTS Municipalities;
CREATE TABLE Municipalities(MunicId integer, Name text, Population integer,
  PercPop float, PopDensityKm2 integer, NoEnterp integer, PercEnterp float,
  Geom geometry);
INSERT INTO Municipalities VALUES
(1,'Anderlecht',118241,0.10,6680,6460,0.08),
(2,'Auderghem - Oudergem',33313,0.03,3701,2266,0.03),
(3,'Berchem-Sainte-Agathe - Sint-Agatha-Berchem',24701,0.02,8518,1266,0.02),
(4,'Etterbeek',176545,0.15,5415,14204,0.18),
(5,'Evere',47414,0.04,15295,3769,0.05),
(6,'Forest - Vorst',40394,0.03,8079,1880,0.02),
(7,'Ganshoren',55746,0.05,8991,3436,0.04),
(8,'Ixelles - Elsene',24596,0.02,9838,1170,0.01),
(9,'Jette',86244,0.07,13690,9304,0.12),
(10,'Koekelberg',51933,0.04,10387,2403,0.03),
(11,'Molenbeek-Saint-Jean - Sint-Jans-Molenbeek',21609,0.02,18008,1064,0.01),
(12,'Saint-Gilles - Sint-Gillis',96629,0.08,16378,4362,0.05),
(13,'Saint-Josse-ten-Noode - Sint-Joost-ten-Node',50471,0.04,20188,3769,0.05),
(14,'Schaerbeek - Schaarbeek',27115,0.02,24650,1411,0.02),
(15,'Uccle - Ukkel',133042,0.11,16425,7511,0.09),
(16,'Ville de Bruxelles - Stad Brussel',82307,0.07,3594,7435,0.09),
(17,'Watermael-Boitsfort - Watermaal-Bosvoorde',24871,0.02,1928,1899,0.02),
(18,'Woluwe-Saint-Lambert - Sint-Lambrechts-Woluwe',55216,0.05,7669,3590,0.04),
(19,'Woluwe-Saint-Pierre - Sint-Pieters-Woluwe',41217,0.03,4631,2859,0.04);

-- Compute the geometry of the communes from the boundaries in planet_osm_line

DROP TABLE IF EXISTS MunicipalitiesGeom;
CREATE TABLE MunicipalitiesGeom(name text, geom geometry, geompoly geometry);
INSERT INTO MunicipalitiesGeom
SELECT name, way AS geom
FROM planet_osm_line L
WHERE name IN ( SELECT name from Municipalities );

/*
-- Ensure all geometries are closed 
SELECT name FROM MunicipalitiesGeom WHERE NOT ST_IsClosed(geom);
*/
-- Create polygons from the LINESTRING geometries
UPDATE MunicipalitiesGeom
SET geompoly = ST_MakePolygon(geom);

-- Disjoint components of Ixelles are encoded as two different features
-- For this reason ST_Union is needed to make a multipolygon
UPDATE Municipalities C
SET geom = (
  SELECT ST_Union(geompoly) FROM MunicipalitiesGeom G
  WHERE C.name = G.name);

-- Clean up tables
DROP TABLE IF EXISTS MunicipalitiesGeom;

-- Create home/work regions and nodes

DROP TABLE IF EXISTS HomeRegions;
CREATE TABLE HomeRegions(MunicId, priority, weight, prob, cumprob, geom) AS
SELECT MunicId, MunicId, population, PercPop,
  SUM(PercPop) OVER (ORDER BY MunicId ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumProb,
  geom
FROM Municipalities;

CREATE INDEX HomeRegions_geom_idx ON HomeRegions USING GiST(geom);

DROP TABLE IF EXISTS WorkRegions;
CREATE TABLE WorkRegions(MunicId, priority, weight, prob, cumprob, geom) AS
SELECT MunicId, MunicId, NoEnterp, PercEnterp,
  SUM(PercEnterp) OVER (ORDER BY MunicId ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumProb,
  geom
FROM Municipalities;

CREATE INDEX WorkRegions_geom_idx ON WorkRegions USING GiST(geom);

DROP TABLE IF EXISTS HomeNodes;
CREATE TABLE HomeNodes AS
SELECT N.*, R.MunicId AS region, R.CumProb
FROM Nodes N, HomeRegions R
WHERE ST_Intersects(R.geom, N.geom);

CREATE INDEX HomeNodes_id_idx ON HomeNodes USING BTREE (NodeId);

DROP TABLE IF EXISTS WorkNodes;
CREATE TABLE WorkNodes AS
SELECT N.*, R.MunicId AS region
FROM Nodes N, WorkRegions R
WHERE ST_Intersects(N.geom, R.geom);

CREATE INDEX WorkNodes_id_idx ON WorkNodes USING BTREE (NodeId);

-------------------------------------------------------------------------------
-- THE END
-------------------------------------------------------------------------------
