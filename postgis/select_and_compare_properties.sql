--Grant Humphries for TriMet, 2014
--PostGIS Version: 2.1
--PostGreSQL Version: 9.3
---------------------------------

--***Taxlots***

--Since parks and water bodies have been 'erased' for taxlots in previous steps the attribute that
--ships with RLIS and contains the area of the feature is no longer valid and the area will be
--recalculated below
alter table trimmed_taxlots drop column if exists habitable_acres cascade;
alter table trimmed_taxlots add habitable_acres numeric;

--Since this data set is in the State Plane projection the output of the ST_Area tool will be in 
--square feet, I want acres and thus will divide that number by 43,560 as that's how many square 
--feet are in an acre
update trimmed_taxlots set habitable_acres = (ST_Area(geom) / 43560);

--------------------------
--CREATE ANALYSIS TAXLOTS
drop table if exists analysis_taxlots cascade;
create table analysis_taxlots (
	gid int references trimmed_taxlots, 
	geom geometry,
	tlid text,
	totalval numeric,
	habitable_acres numeric,
	prop_code text,
	landuse text,
	yearbuilt int,
	max_year int,
	max_zone text,
	near_max boolean,
	walk_dist numeric,
	ugb boolean,
	tm_dist boolean,
	nine_cities boolean)
with oids;

--Spatially join tax lots and the isochrones (the former of which indicates area that are within a given
--walking distance of max stops).  The output is tax lots joined to attribute information of the isochrones
--that they intersect.  Note that there are intentionally duplicates in this table if a taxlot is within
--walking distance multiple stops that are in different 'MAX Zones', but duplicates of a property within
--the same MAX Zone are eliminated
insert into analysis_taxlots (gid, geom, tlid, totalval, habitable_acres, prop_code, landuse,
		yearbuilt, max_year, max_zone, near_max, walk_dist)
	select tt.gid, tt.geom, tt.tlid, tt.totalval, tt.habitable_acres, tt.prop_code, tt.landuse,
		tt.yearbuilt, min(iso.incpt_year), iso.max_zone, true, iso.walk_dist
	from trimmed_taxlots tt
		join isochrones iso
		--This command joins two features only if they intersect
		on ST_Intersects(tt.geom, iso.geom)
	group by tt.gid, tt.geom, tt.tlid, tt.totalval, tt.habitable_acres, tt.prop_code, tt.landuse,
		tt.yearbuilt, iso.max_zone, iso.walk_dist;

--clean up after insert
vacuum analyze analysis_taxlots;

--should speed performance on nearest neighbor operation below
cluster trimmed_taxlots using trimmed_taxlots_geom_gist;
analyze trimmed_taxlots;

--Insert taxlots that are not within walking distance of max stops into analysis_taxlots 
insert into analysis_taxlots (gid, geom, tlid, totalval, habitable_acres, prop_code,
		landuse, yearbuilt, max_zone, near_max)
	select tt.gid, tt.geom, tt.tlid, tt.totalval, tt.habitable_acres, 
		tt.prop_code, tt.landuse, tt.yearbuilt, 
		--Finds nearest neighbor in the max stops data set for each taxlot and returns the stop's 
		--corresponding 'MAX Zone' (a zone was assigned to each stop earlier in the project),
		--derived from (http://gis.stackexchange.com/questions/52792/calculate-min-distance-between-points-in-postgis)
		(select mxs.max_zone
			from max_stops mxs 
			order by tt.geom <-> mxs.geom 
			limit 1), false
	from trimmed_taxlots tt
	where tt.gid not in (select gid from analysis_taxlots);

--clean up after inserts
vacuum analyze analysis_taxlots;

--Assign the max year based on the max zone, this method is being used because repeating the 
--nearest neighbor method to get the year is far more computationally intensive

--Create a mapping from MAX zones to MAX years. Note that there are multiple years that map to the
--CBD zone and in this case the minimum year will be returned
drop table if exists max_year_zone_mapping cascade;
create temp table max_year_zone_mapping as
	select max_zone, min(incpt_year) as max_year
	from max_stops
	group by max_zone;

--Indices are added to decrease match time below
drop index if exists max_mapping_ix cascade;
create index max_mapping_ix on max_year_zone_mapping using BTREE (max_zone);

drop index if exists a_taxlot_near_max_ix cascade;
create index a_taxlot_near_max_ix on analysis_taxlots using BTREE (near_max);

--Populate max_year column for properties outside walking distance of max stops based on 
--max_year_zone_mapping table.  Note that is value is already populated for properties within
--walking distance of MAX and should not be overwitten
update analysis_taxlots atx set max_year = yzm.max_year
	from max_year_zone_mapping yzm
	where yzm.max_zone = atx.max_zone
		--this clause is very important, if not present decision to build year for tax lots within
		--walking distance of max would be overwritten which would lead to incorrect results
		and atx.near_max is false;

--Add index to improve performance on upcoming spatial comparisons
drop index if exists a_taxlot_gix cascade;
create index a_taxlot_gix on analysis_taxlots using GIST (geom);

cluster analysis_taxlots using a_taxlot_gix;
vacuum analyze analysis_taxlots;

--Temp table will turn the 9 most populous cities in the TM district into a single geometry
drop table if exists nine_cities cascade;
create temp table nine_cities as
	select ST_Union(geom) as geom
	from (select city.gid, city.geom, 1 as collapser
 		from city
 		where cityname in ('Portland', 'Gresham', 'Hillsboro', 'Beaverton', 
 			'Tualatin', 'Tigard', 'Lake Oswego', 'Oregon City', 'West Linn')) as collapsable_city
	group by collapser;

--Determine if each of the analysis taxlots is in the trimet district, urban growth boundary, 
--and city limits of the nine biggest cities in the Portland metro area (Oregon only)
update analysis_taxlots as atx set
	--Returns True if a taxlot intersects the urban growth boundary
	ugb = (select ST_Intersects(ugb.geom, atx.geom)
		from ugb),
	--Returns True if a taxlot intersects the TriMet's service district boundary
	tm_dist = (select ST_Intersects(td.geom, atx.geom)
		from tm_district td),
	--Returns True if a taxlot intersects one of the nine most populous cities in the TM dist
	nine_cities = (select ST_Intersects(nc.geom, atx.geom)
		from nine_cities nc);


-----------------------------------------------------------------------------------------------------------------
--***Multi-Family Housing Units***
--Works off the same framework as what is used for tax lots above

alter table trimmed_multifam drop column if exists habitable_acres cascade;
alter table trimmed_multifam add habitable_acres numeric;

update trimmed_multifam set habitable_acres = (ST_Area(geom) / 43560);

--------------------------
--CREATE ANALYSIS MULTIFAM
--Divisors for overall area comparisons will still come from analysis_taxlots, but numerators
--will come from the table below.  This because the multi-family layer doesn't have full coverage
--of all buildable land in the region the way the tax lot data does
drop table if exists analysis_multifam cascade;
create table analysis_multifam (
	gid int references trimmed_multifam, 
	geom geometry,
	metro_id int,
	units int,
	unit_type text,
	habitable_acres numeric,
	mixed_use int,
	yearbuilt int,
	max_year int,
	max_zone text,
	near_max boolean,
	walk_dist numeric,
	ugb boolean,
	tm_dist boolean,
	nine_cities boolean)
with oids;

insert into analysis_multifam (gid, geom, metro_id, units, unit_type, habitable_acres, mixed_use, 
		yearbuilt, max_year, max_zone, near_max, walk_dist)
	select tm.gid, tm.geom, tm.metro_id, tm.units, tm.unit_type, tm.habitable_acres, tm.mixed_use,
		tm.yearbuilt, min(iso.incpt_year), iso.max_zone, true, iso.walk_dist
	from trimmed_multifam tm
		join isochrones iso
		on ST_Intersects(tm.geom, iso.geom)
	group by tm.gid, tm.geom, tm.metro_id, tm.units, tm.yearbuilt, tm.unit_type, tm.habitable_acres, 
		tm.mixed_use, iso.max_zone, iso.walk_dist;

vacuum analyze analysis_multifam;

cluster trimmed_multifam using trimmed_multifam_geom_gist;
analyze trimmed_multifam;

--Insert multifam units outside of walking distance into the analysis-multifam
insert into anlysis_multifam (gid, geom, metro_id, units, unit_type, habitable_acres,
		mixed_use, yearbuilt, max_zone, near_max)
	select tm.gid, tm.geom, tm.metro_id, tm.units, tm.unit_type, tm.habitable_acres,
		tm.mixed_use, tm.yearbuilt,
		--get max zone for nearest stop using nearest neighbor
		(select mxs.max_zone
			from max_stops mxs 
			order by tm.geom <-> mxs.geom 
			limit 1), false
	from trimmed_multifam tm
	where tm.gid not in (select gid from analysis_multifam);

vacuum analyze analysis_multifam;

--Populate max_year column for properties outside max stop walking distance based on
--max_year_zone_mapping table
update analyis_multifam amf set max_year = yzm.max_year
	from max_year_zone_mapping yzm
	where yzm.max_zone = amf.max_zone
		and amf.near_max is false;

--Should improve performance on upcoming spatial comparisons
drop index if exists a_multifam_gix cascade;
create index a_multifam_gix on analysis_multifam using GIST (geom);

cluster analysis_multifam using a_multifam_gix;
vacuum analyze analysis_multifam;

update analysis_multifam as amf set
	ugb = (select ST_Intersects(ugb.geom, amf.geom)
		from ugb),

	tm_dist = (select ST_Intersects(td.geom, amf.geom)
		from tm_district td),

	nine_cities = (select ST_Intersects(nc.geom, amf.geom)
		from nine_cities nc);

--Temp table is no longer needed
drop table max_year_zone_mapping cascade;
drop table nine_cities cascade;

--ran in ~4,702,524 ms on 5/20/14 (definitely benefitted from some caching though)