-- Unused stuff

DROP TABLE public.languages;
COMMENT ON TABLE public.migrations IS '@omit';
DROP FUNCTION public.get_producing_countries();

-- Use data point table for all kinds of projects.

ALTER TABLE public.sparse_projects RENAME TO project;
CREATE TYPE project_type AS ENUM (
    'dense',
    'sparse');
ALTER TABLE public.project ADD COLUMN IF NOT EXISTS project_type project_type NOT NULL DEFAULT 'sparse'::project_type;

-- Unify naming

ALTER TABLE public.sparse_data_point RENAME TO project_data_point;
ALTER TABLE public.country_production RENAME TO country_data_point;
ALTER TABLE public.countries RENAME TO country;
ALTER TABLE public.country_data_point RENAME COLUMN source_operator_name TO operator_name;
ALTER TABLE public.country_data_point ADD COLUMN IF NOT EXISTS subtype varchar(20) NULL;

-- Convert from projection flag to data_point_type

ALTER TYPE sparse_data_point_type RENAME TO data_point_type;
ALTER TABLE public.country_data_point ADD COLUMN IF NOT EXISTS data_type data_point_type NULL;
UPDATE public.country_data_point SET data_type = 'production'::data_point_type WHERE projection = FALSE;
UPDATE public.country_data_point SET data_type = 'projection'::data_point_type WHERE projection = TRUE;
ALTER TABLE public.country_data_point ALTER COLUMN data_type SET NOT NULL;

-- Convert dense projects

INSERT INTO public.project (iso3166, iso3166_2, project_id, project_type, operator_name, oc_operator_id)
    (SELECT DISTINCT iso3166, iso3166_2, project_id, 'dense'::project_type AS project_type, operator_name, oc_operator_id FROM public.country_data_point cp WHERE project_id <> '')
ON CONFLICT DO NOTHING;

DROP INDEX public.country_production_3;
ALTER TABLE public.country_data_point RENAME COLUMN project_id TO project_identifier;
ALTER TABLE public.country_data_point DROP COLUMN operator_name;
ALTER TABLE public.country_data_point DROP COLUMN oc_operator_id;
ALTER TABLE public.country_data_point ADD COLUMN IF NOT EXISTS project_id integer;

UPDATE public.country_data_point SET project_id = p.id
FROM (SELECT * FROM public.project) p
WHERE p.iso3166 = country_data_point.iso3166 AND p.project_id = country_data_point.project_identifier;

ALTER TABLE public.country_data_point DROP COLUMN project_identifier;
ALTER TABLE public.project_data_point RENAME COLUMN sparse_project_id TO project_id;

-- Merge geo data

UPDATE public.project SET geo_position = pg.geom
FROM (SELECT * FROM public.project_geo) pg
WHERE pg.iso3166 = project.iso3166 AND pg.project_id = project.project_id;

DROP TABLE public.project_geo;

-- Now convert dense data points

INSERT INTO public.project_data_point (project_id, volume, unit, YEAR, source_id, fossil_fuel_type, data_type)
    (SELECT project_id, volume, unit, YEAR, source_id, fossil_fuel_type, 'production' AS data_type FROM public.country_data_point cdp WHERE project_id IS NOT NULL AND volume IS NOT NULL AND projection = false);

INSERT INTO public.project_data_point (project_id, volume, unit, YEAR, source_id, fossil_fuel_type, data_type)
    (SELECT project_id, volume, unit, YEAR, source_id, fossil_fuel_type, 'projection' AS data_type FROM public.country_data_point cdp WHERE project_id IS NOT NULL AND volume IS NOT NULL AND projection = true);

DELETE FROM public.country_data_point WHERE project_id IS NOT NULL;
ALTER TABLE public.country_data_point DROP COLUMN project_id;
ALTER TABLE public.country_data_point DROP COLUMN projection;

-- Convert reserves (Fix iso3166 errors first)

UPDATE public.country_reserves SET iso3166 = 'pl' WHERE iso3166 = 'po';
ALTER TABLE public.country_data_point ADD COLUMN IF NOT EXISTS quality integer;
ALTER TABLE public.country_data_point ADD COLUMN IF NOT EXISTS grade text;
INSERT INTO public.country_data_point (iso3166, volume, unit, YEAR, source_id, fossil_fuel_type, data_type, grade, quality)
    (SELECT iso3166, volume, unit, YEAR, source_id, fossil_fuel_type, 'reserve' AS data_type, grade, quality FROM public.country_reserves WHERE volume IS NOT NULL);
DROP TABLE public.country_reserves;

-- Improve FKs

ALTER TABLE public.country_data_point RENAME CONSTRAINT country_production_pk TO country_data_point_pk;
ALTER TABLE public.country_data_point DROP CONSTRAINT country_production_fk;
ALTER INDEX country_production_iso3166_idx RENAME TO country_data_point_iso3166_idx;

UPDATE public.country_data_point SET iso3166_2 = '' WHERE iso3166_2 IS NULL;
ALTER TABLE public.country_data_point ALTER COLUMN iso3166_2 SET NOT NULL;
ALTER TABLE public.country_data_point ALTER COLUMN iso3166_2 SET DEFAULT '';

ALTER TABLE public.country_data_point ADD CONSTRAINT country_data_point_fk FOREIGN KEY (iso3166,iso3166_2) REFERENCES public.country(iso3166,iso3166_2) ON DELETE CASCADE;

ALTER TABLE public.project RENAME CONSTRAINT sparse_projects_pk TO projects_pk;

UPDATE public.country SET iso3166_2 = '' WHERE iso3166_2 IS NULL;
ALTER TABLE public.country ALTER COLUMN iso3166_2 SET NOT NULL;
ALTER TABLE public.country ALTER COLUMN iso3166_2 SET DEFAULT '';

UPDATE public.project SET iso3166_2 = '' WHERE iso3166_2 IS NULL;
ALTER TABLE public.project ALTER COLUMN iso3166_2 SET NOT NULL;
ALTER TABLE public.project ALTER COLUMN iso3166_2 SET DEFAULT '';

ALTER TABLE public.project ADD CONSTRAINT project_fk FOREIGN KEY (iso3166,iso3166_2) REFERENCES public.country(iso3166,iso3166_2) ON DELETE CASCADE;

ALTER TABLE public.project RENAME COLUMN project_id TO project_identifier;

-- ---------------------------------------------------

CREATE OR REPLACE VIEW sparse_projects AS
SELECT p.iso3166,
       p.iso3166_2,
       p.project_identifier,
       pdp.year,
       pdp.volume,
       pdp.unit,
       pdp.fossil_fuel_type,
       pdp.subtype,
       pdp.source_id,
       pdp.data_type
FROM public.project p,
     public.project_data_point pdp
WHERE p.id = pdp.project_id
  AND p.project_type = 'sparse'
ORDER BY p.project_identifier, pdp.data_type, pdp.year;
COMMENT ON VIEW public.sparse_projects IS '@omit';
GRANT ALL ON TABLE public.sparse_projects TO grff;

CREATE OR REPLACE VIEW public.dense_projects
AS SELECT p.iso3166,
          p.iso3166_2,
          p.project_identifier,
          p.production_co2e,
          pdp.year,
          pdp.volume,
          pdp.unit,
          pdp.fossil_fuel_type,
          pdp.subtype,
          pdp.source_id,
          pdp.data_type
   FROM project p,
        project_data_point pdp
   WHERE p.id = pdp.project_id AND p.project_type = 'dense'::project_type
   ORDER BY p.project_identifier, pdp.data_type, pdp.year;
COMMENT ON VIEW public.dense_projects IS '@omit';
GRANT ALL ON TABLE public.dense_projects TO grff;

CREATE OR REPLACE FUNCTION public.get_producing_iso3166()
    RETURNS TABLE(iso3166 text, iso3166_2 text, en text, fr text, es text, sv text)
    LANGUAGE sql
    STABLE
AS $function$
SELECT DISTINCT prod.iso3166, prod.iso3166_2, c.en, c.fr, c.es, c.sv FROM
    (SELECT DISTINCT iso3166, COALESCE(iso3166_2, '') AS iso3166_2 FROM public.country_data_point) prod
        JOIN public.country c ON c.iso3166 = prod.iso3166 AND c.iso3166_2 = prod.iso3166_2
ORDER BY prod.iso3166;
$function$;

DROP FUNCTION public.get_sources(text,text,text);
DROP FUNCTION IF EXISTS public.get_production_sources( text, text,  text);
DROP FUNCTION IF EXISTS public.get_projection_sources( text, text,  text);
DROP FUNCTION IF EXISTS public.get_reserves_sources( text, text,  text);

DROP FUNCTION IF EXISTS public.get_projects(text,text);
CREATE OR REPLACE FUNCTION public.get_projects(iso3166_ text, iso3166_2_ text)
    RETURNS TABLE(id integer, project_identifier text, co2 float, first_year integer, last_year integer, type project_type)
    LANGUAGE sql
    STABLE
AS $function$
    SELECT p.id, p.project_identifier, p.production_co2e, min(pdp.year) AS first_year, max(pdp.year) as last_year, p.project_type AS last_year
        FROM public.project p, public.project_data_point pdp
        WHERE p.id = pdp.project_id AND (iso3166_ = p.iso3166 AND iso3166_2_ = p.iso3166_2)
        GROUP BY p.id
        ORDER BY p.project_identifier;
$function$;

CREATE OR REPLACE FUNCTION public.get_country_sources(iso3166_ text, iso3166_2_ text DEFAULT ''::text)
    RETURNS TABLE(
                     source_id integer, name text, name_pretty text, description text, url text,
                     records bigint, data_points bigint, latest_curation_at timestamp without time zone,
                     data_type data_point_type, quality integer, grades TEXT[], year integer)
    LANGUAGE sql
    STABLE
AS $function$
SELECT DISTINCT s.*, dp.data_type, dp.quality, array_agg(dp.grade), max(dp.YEAR)
FROM sources s, country_data_point dp
WHERE s.source_id = dp.source_id AND iso3166_ = dp.iso3166 AND dp.iso3166_2 = iso3166_2_
GROUP BY s.source_id, dp.data_type, dp.quality
UNION
SELECT s.*, 'projection'::data_point_type AS data_type, 1 as quality, array['xp'] as grades, 2020 AS year FROM sources s
WHERE s.source_id = 100;
$function$;

CREATE OR REPLACE FUNCTION public.get_project_sources( for_id integer )
    RETURNS TABLE(
                     source_id int4,
                     "name" text,
                     name_pretty text,
                     description text,
                     url text,
                     records int8,
                     data_points int8,
                     latest_curation_at timestamp,
                     data_type data_point_type,
                     quality integer,
                     grade text
                 )
    LANGUAGE sql
    STABLE
AS $function$
SELECT DISTINCT s.*, dp.data_type, dp.quality, dp.grade FROM sources s, project_data_point dp
WHERE s.source_id = dp.source_id AND for_id = dp.project_id
UNION
SELECT s.*, 'projection'::data_point_type AS data_type, 1 as quality, 'xp' as grade FROM sources s
WHERE s.source_id = 100;
$function$;

CREATE OR REPLACE FUNCTION public.get_country_current_production(iso3166_ text)
    RETURNS TABLE(id integer, year integer, volume double precision, unit text, fossil_fuel_type text, source_id integer)
    LANGUAGE sql
    STABLE
AS $function$
SELECT id, year, volume, unit, fossil_fuel_type, source_id FROM (
    SELECT *, RANK() OVER (PARTITION BY source_id, fossil_fuel_type ORDER BY year DESC) FROM public.country_data_point cp
    WHERE cp.iso3166 = iso3166_ AND data_type = 'production'
    ORDER BY RANK
) t WHERE RANK=1;
$function$;