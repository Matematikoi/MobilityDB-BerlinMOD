/******************************************************************************
 * Loads the Brussels synthetic dataset obtained from the BerlinMOD generator
 * in CSV format 
 * https://github.com/MobilityDB/MobilityDB-BerlinMOD
 * into MobilityDB using projected (2D) coordinates with SRID 3857
 * https://epsg.io/3857
 * Parameters:
 * - fullpath: states the full path in which the CSV files are located.
 * - gist: states whether GiST or SP-GiST indexes are created on the tables.
 *     By default it is set to TRUE and thus creates GiST indexes.
 * The following files are expected to be in the given path
 * - instants.csv
 * - periods.csv
 * - points.csv
 * - regions.csv
 * - vehicles.csv
 * - licences.csv
 * - municipalities.csv
 * - tripsinput.csv
 *
 * Example of usage on psql:
 *     CREATE EXTENSION mobilitydb CASCADE;
 *     \i berlinmod_load.sql
 *     SELECT berlinmod_load('/home/mobilitydb/data/');
 *****************************************************************************/

DROP FUNCTION IF EXISTS berlinmod_load;
CREATE OR REPLACE FUNCTION berlinmod_load(fullpath text, gist bool DEFAULT TRUE) 
RETURNS text AS $$
DECLARE
  startTime timestamptz;
  endTime timestamptz;
BEGIN
--------------------------------------------------------------

  startTime = clock_timestamp();
  RAISE INFO '------------------------------------------------------------------';
  RAISE INFO 'Loading synthetic data from the BerlinMOD data generator';
  RAISE INFO '------------------------------------------------------------------';
  RAISE INFO 'Execution started at %', startTime;
  RAISE INFO '------------------------------------------------------------------';

--------------------------------------------------------------

  RAISE INFO 'Creating table Instants';
  DROP TABLE IF EXISTS Instants CASCADE;
  CREATE TABLE Instants
  (
    InstantId integer PRIMARY KEY,
    Instant timestamptz
  );
  EXECUTE format('COPY Instants(InstantId, Instant)
    FROM ''%sinstants.csv'' DELIMITER '','' CSV HEADER', fullpath);

  CREATE VIEW Instants1 (InstantId, Instant) AS
  SELECT InstantId, Instant 
  FROM Instants
  LIMIT 10;

--------------------------------------------------------------

  RAISE INFO 'Creating table Periods';
  DROP TABLE IF EXISTS Periods CASCADE;
  CREATE TABLE Periods
  (
    PeriodId integer PRIMARY KEY,
    StartTime timestamptz,
    EndTime timestamptz,
    Period tstzspan
  );
  EXECUTE format('COPY Periods(PeriodId, StartTime, EndTime, Period)
    FROM ''%speriods.csv'' DELIMITER '','' CSV HEADER', fullpath);

  IF gist THEN
    CREATE INDEX Periods_Period_gist_idx ON Periods USING gist (Period);
  ELSE
    CREATE INDEX Periods_Period_spgist_idx ON Periods USING spgist (Period);
  END IF;
  
  CREATE VIEW Periods1 (PeriodId, StartTime, EndTime, Period) AS
  SELECT PeriodId, StartTime, EndTime, Period
  FROM Periods
  LIMIT 10;

--------------------------------------------------------------

  RAISE INFO 'Creating table Points';
  DROP TABLE IF EXISTS Points CASCADE;
  CREATE TABLE Points
  (
    PointId integer PRIMARY KEY,
    Geom geometry(Point,3857)
  );
  EXECUTE format('COPY Points(PointId, Geom)
    FROM ''%spoints.csv'' DELIMITER '','' CSV HEADER', fullpath);

  IF gist THEN
    CREATE INDEX Points_geom_gist_idx ON Points USING gist(Geom);
  ELSE
    CREATE INDEX Points_geom_spgist_idx ON Points USING spgist(Geom);
  END IF;

  CREATE VIEW Points1 (PointId, Geom) AS
  SELECT PointId, Geom
  FROM Points
  LIMIT 10;

--------------------------------------------------------------

  DROP TABLE IF EXISTS Regions CASCADE;
  CREATE TABLE Regions
  (
    RegionId integer PRIMARY KEY,
    Geom Geometry(Polygon,3857)
  );
  EXECUTE format('COPY Regions(RegionId, Geom)
    FROM ''%sregions.csv'' DELIMITER '','' CSV HEADER', fullpath);

  IF gist THEN
    CREATE INDEX Regions_geom_gist_idx ON Regions USING gist (Geom);
  ELSE
    CREATE INDEX Regions_geom_spgist_idx ON Regions USING spgist (Geom);
  END IF;

  CREATE VIEW Regions1 (RegionId, Geom) AS
  SELECT RegionId, Geom
  FROM Regions
  LIMIT 10;

--------------------------------------------------------------

  RAISE INFO 'Creating table Vehicles';
  DROP TABLE IF EXISTS Vehicles CASCADE;
  CREATE TABLE Vehicles
  (
    VehId integer PRIMARY KEY,
    Licence varchar(32),
    VehType varchar(32),
    Model varchar(32)
  );
  EXECUTE format('COPY Vehicles(VehId, Licence, VehType, Model)
    FROM ''%svehicles.csv'' DELIMITER '','' CSV HEADER', fullpath);
  
--------------------------------------------------------------

  RAISE INFO 'Creating table Licences';
  DROP TABLE IF EXISTS Licences CASCADE;
  CREATE TABLE Licences
  (
    LicenceId integer PRIMARY KEY,
    Licence text,
    VehId integer,
    FOREIGN KEY (VehId) REFERENCES Vehicles(VehId)
  );
  EXECUTE format('COPY Licences(LicenceId, Licence, VehId)
    FROM ''%slicences.csv'' DELIMITER '','' CSV HEADER', fullpath);

  CREATE INDEX Licences_VehId_idx ON Licences USING btree (VehId);

  CREATE VIEW Licences1 (LicenceId, Licence, VehId) AS
  SELECT LicenceId, Licence, VehId
  FROM Licences
  LIMIT 10;

  CREATE VIEW Licences2 (LicenceId, Licence, VehId) AS
  SELECT LicenceId, Licence, VehId
  FROM Licences
  LIMIT 10 OFFSET 10;

--------------------------------------------------------------

  RAISE INFO 'Creating table Municipalities';
  DROP TABLE IF EXISTS Municipalities CASCADE;
  CREATE TABLE Municipalities
  (
    MunicipalityId integer PRIMARY KEY,
    Name text NOT NULL,
    Population integer,
    PercPop numeric,
    PopDensityKm2 integer,
    NoEnterp integer,
    PercEnterp numeric,
    geom geometry NOT NULL
  );
  EXECUTE format('COPY Municipalities(MunicipalityId, Name, Population,
      PercPop, PopDensityKm2, NoEnterp, PercEnterp, Geom)
    FROM ''%smunicipalities.csv'' DELIMITER '','' CSV HEADER', fullpath);

  IF gist THEN
    CREATE INDEX Municipalities_gist_idx ON Municipalities USING gist(Geom);
  ELSE
    CREATE INDEX Municipalities_spgist_idx ON Municipalities USING spgist(Geom);
  END IF;

--------------------------------------------------------------

  RAISE INFO 'Creating table TripsInput';
  DROP TABLE IF EXISTS TripsInput CASCADE;
  CREATE TABLE TripsInput
  (
    TripId integer NOT NULL,
    VehId integer NOT NULL,
    StartDate date,
    SeqNo int,
    Point geometry(Point, 3857) NOT NULL,
    T timestamptz NOT NULL
  )
  WITH (
    autovacuum_enabled = false,
    toast.autovacuum_enabled = false
  );
  EXECUTE format('COPY TripsInput(TripId, VehId, StartDate, SeqNo, Point, T)
    FROM ''%stripsinput.csv'' DELIMITER '','' CSV HEADER', fullpath);

  RAISE INFO 'Creating table Trips';
  DROP TABLE IF EXISTS Trips CASCADE;
  CREATE TABLE Trips
  (
    TripId integer PRIMARY KEY,
    VehId integer NOT NULL,
    StartDate date,
    SeqNo int,
    Trip tgeompoint NOT NULL,
    Trajectory geometry,
    FOREIGN KEY (VehId) REFERENCES Vehicles(VehId) 
  );

  INSERT INTO Trips(TripId, VehId, StartDate, SeqNo, Trip)
  SELECT TripId, VehId, StartDate, SeqNo,
    tgeompointSeq(array_agg(tgeompoint(Point, T) ORDER BY T))
  FROM TripsInput
  GROUP BY VehId, TripId, StartDate, SeqNo;

  UPDATE Trips
  SET Trajectory = trajectory(Trip);

  CREATE INDEX Trips_VehId_idx ON Trips USING btree(VehId);

  IF gist THEN
    CREATE INDEX Trips_gist_idx ON Trips USING gist(trip);
  ELSE
    CREATE INDEX Trips_spgist_idx ON Trips USING spgist(trip);
  END IF;
  
  DROP VIEW IF EXISTS Trips1;
  CREATE VIEW Trips1 AS
  SELECT * FROM Trips LIMIT 100;
  
--------------------------------------------------------------

  endTime = clock_timestamp();
  RAISE INFO '------------------------------------------------------------------';
  RAISE INFO 'Execution started at %', startTime;
  RAISE INFO 'Execution finished at %', endTime;
  RAISE INFO 'Execution time %', endTime - startTime;
  RAISE INFO '------------------------------------------------------------------';

-------------------------------------------------------------------------------

  -- DROP TABLE TripsInput;

  RETURN 'The End';
END;
$$ LANGUAGE 'plpgsql';

-------------------------------------------------------------------------------
