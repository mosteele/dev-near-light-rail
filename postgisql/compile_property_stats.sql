--This script generates a measure of real estate growth for properties with
--the max isochrones and that were built upon since the decision to build the
--nearby max line as well as figures that quantify real estate growth in the
--Portland metro region as a whole, for comparison purposes

--Create versions of taxlot and multifam tables that remove the
--duplicates that exist when properties are within walking distance of
--multiple stops that have different 'max zone' associations, these
--will be used to remove double counting from regional totals
drop table if exists unique_taxlots cascade;
create table unique_taxlots (
    gid int primary key references taxlots,
    geom geometry(MultiPolygon, 2913),
    totalval numeric,
    gis_acres numeric,
    yearbuilt int,
    max_year int,
    max_zone text,
    near_max boolean,
    walk_dist numeric,
    tm_dist boolean,
    ugb boolean,
    nine_cities boolean
);

insert into unique_taxlots
    select 
        gid, geom, totalval, gis_acres, yearbuilt, min(max_year), null, 
        near_max, min(walk_dist), tm_dist, ugb, nine_cities
    from max_taxlots
    group by 
        gid, geom, totalval, gis_acres, yearbuilt, near_max, tm_dist, ugb, 
        nine_cities;

drop table if exists unique_multifam cascade;
create table unique_multifam (
    gid int primary key references multifamily,
    geom geometry(MultiPolygon, 2913),
    units int,
    yearbuilt int,
    max_year int,
    max_zone text,
    near_max boolean,
    tm_dist boolean,
    ugb boolean,
    nine_cities boolean
);

insert into unique_multifam
    select
        gid, geom, units, yearbuilt, min(max_year), null, near_max, tm_dist,
        ugb, nine_cities
    from max_multifam
    group by gid, geom, units, yearbuilt, near_max, tm_dist, ugb, nine_cities;

drop table if exists property_stats cascade;
create table property_stats (
    group_desc text,
    max_zone text,
    max_year text,
    walk_dist text,
    totalval numeric,
    housing_units int,
    gis_acres numeric,
    group_rank int,
    zone_rank int,
    primary key (group_desc, max_zone)
);

-- A call to this function adds one or more entries to the
--'property_stats' table, the contents of those entries are dictated by
--the function parameters
create or replace function insert_property_stats(
    region text, group_method text, includes_max boolean) returns void as $$
declare
    desc_str text;
    grouping_field text;
    taxlot_table text;
    multifam_table text;

    zone_clause text := '';
    not_near_clause text := '';
    group_rank text := 0;
    zone_rank text := 0;

begin
    if region = 'near_max' then
        desc_str := 'Properties in MAX walk shed';
        group_rank := 1;
    elsif region = 'ugb' then
        desc_str := 'Urban Growth Boundary';
    elsif region = 'tm_dist' then
        desc_str := 'TriMet District';
    elsif region = 'nine_cities' then
        desc_str := 'Nine largest cities in TriMet District';
    else
        raise exception 'invalid input for ''region'' parameter'
            using hint = 'accepted values are ''near_max'', ''ugb'', ' ||
                         '''tm_dist'' and ''nine_cities''';
    end if;

    --'group_method' determines whether a set of entries will be
    --created for each max zone within the current region or whether a
    --single entry will be created that describes the region as a whole

    --a single tax lot can belong to multiple zones, and will be
    --counted in each, a region-wide count eliminates duplicates
    if group_method = 'zone' then
        grouping_field := 'max_zone';
        taxlot_table := 'max_taxlots';
        multifam_table := 'max_multifam';
        zone_clause := 'AND max_zone = tx1.max_zone';
    elsif group_method = 'region' then
        grouping_field := region;
        taxlot_table := 'unique_taxlots';
        multifam_table := 'unique_multifam';
        zone_rank := 1;
    else
        raise exception 'invalid input for ''group_method'' parameter'
            using hint = 'accepted values for are ''zone'' and ''region''';
    end if;

    --the 'includes_max' parameter indicates whether the properties
    --within walking distance of max stops are to be included
    if includes_max is false then
        desc_str := desc_str || ' (not in walk shed)';
        not_near_clause := 'AND near_max IS FALSE';
    elsif includes_max != true then
        raise exception 'invalid input for ''includes_max'' parameter'
            using hint = 'must be a boolean';
    end if;

    execute format(
        'INSERT INTO property_stats '                                     ||
        '    SELECT '                                                     ||
        '        %1$L::text, '                                            ||
        '        coalesce(string_agg( '                                   ||
        '            DISTINCT max_zone, '', ''), ''All Zones''), '        ||
        '        array_to_string(array_agg( '                             ||
        '            DISTINCT max_year '                                  ||
        '            ORDER by max_year), '', ''), '                       ||
        '        CASE '                                                   ||
        '            WHEN -1 = ANY(array_agg(coalesce(walk_dist, -1))) '  ||
        '                THEN NULL '                                      ||
        '            ELSE string_agg( '                                   ||
        '                DISTINCT walk_dist::int::text, '', '') '         ||
        '        END, '                                                   ||
        '        sum(totalval), '                                         ||
        '        (SELECT sum(units) '                                     ||
        '             FROM %2$I '                                         ||
        '             WHERE yearbuilt >= max_year '                       ||
        '                 AND %3$I IS TRUE '                              ||
        '                 %4$s '                                          ||
        '                 %5$s '                                          ||
        '             GROUP BY %6$I), '                                   ||
        '        (SELECT SUM(gis_acres) '                                 ||
        '             FROM %7$I '                                         ||
        '             WHERE %3$I IS TRUE '                                ||
        '                 %4$s '                                          ||
        '                 %5$s '                                          ||
        '             GROUP BY %6$I), '                                   ||
        '        %8$s, '                                                  ||
        '        %9$s '                                                   ||
        '    FROM %7$I tx1 '                                              ||
        '    WHERE yearbuilt >= max_year '                                ||
        '        AND %3$I IS TRUE '                                       ||
        '        %5$s '                                                   ||
        '    GROUP BY %6$I;',
        desc_str, multifam_table, region, zone_clause, not_near_clause,
        grouping_field, taxlot_table, group_rank, zone_rank);
end;
$$ language plpgsql;


--Properties within walking distance of MAX
select insert_property_stats('near_max', 'zone', true);
select insert_property_stats('near_max', 'region', true);

--Comparison properties *including* those within walking distance of MAX
select insert_property_stats('ugb', 'zone', true);
select insert_property_stats('ugb', 'region', true);
select insert_property_stats('tm_dist', 'zone', true);
select insert_property_stats('tm_dist', 'region', true);
select insert_property_stats('nine_cities', 'zone', true);
select insert_property_stats('nine_cities', 'region', true);

--Comparison properties *excluding* those within walking distance of MAX
select insert_property_stats('ugb', 'zone', false);
select insert_property_stats('ugb', 'region', false);
select insert_property_stats('tm_dist', 'zone', false);
select insert_property_stats('tm_dist', 'region', false);
select insert_property_stats('nine_cities', 'zone', false);
select insert_property_stats('nine_cities', 'region', false);


--Populate and sort final stats tables, these will be written to csv,
--stats are split into those that include MAX walk shed taxlots and
--those that do not

drop table if exists final_stats cascade;
create table final_stats as
    select
        group_desc, max_zone, max_year, walk_dist, totalval, housing_units,
        gis_acres, (totalval / gis_acres) as totalval_per_acre,
        (housing_units / gis_acres) as units_per_acre
    from property_stats
    where group_desc not like '%(not in walk shed)%'
    order by zone_rank desc, max_zone, group_rank desc, group_desc;

alter table final_stats add primary key (group_desc, max_zone);

drop table if exists final_stats_minus_max cascade;
create table final_stats_minus_max as
    select
        group_desc, max_zone, max_year, walk_dist, totalval, housing_units,
        gis_acres, (totalval / gis_acres) as totalval_per_acre,
        (housing_units / gis_acres) as units_per_acre
    from property_stats
    where group_desc like '%(not in walk shed)%'
        or group_desc = 'Properties in MAX walk shed'
    order by zone_rank desc, max_zone, group_rank desc, group_desc;

alter table final_stats_minus_max add primary key (group_desc, max_zone);
