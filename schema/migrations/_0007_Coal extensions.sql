DROP FUNCTION get_country_current_production(text);
CREATE OR REPLACE FUNCTION public.get_country_current_production(iso3166_ text)
 RETURNS TABLE(id integer, year integer, volume double precision, unit text, fossil_fuel_type text, source_id integer, subtype text)
 LANGUAGE sql
 STABLE
AS $function$
SELECT id, year, volume, unit, fossil_fuel_type, source_id, subtype FROM (
    SELECT *, RANK() OVER (PARTITION BY source_id, fossil_fuel_type ORDER BY year DESC) FROM public.country_data_point cp
    WHERE cp.iso3166 = iso3166_ AND data_type = 'production'
    ORDER BY RANK
) t WHERE RANK=1;
$function$;


CREATE OR REPLACE FUNCTION project_fuels(project project) RETURNS character varying[] AS $$
  SELECT ARRAY_AGG(DISTINCT project_data_point.fossil_fuel_type) FROM public.project_data_point WHERE project_id = project.id
$$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION public.project_fuels(project) TO grff;

CREATE OR REPLACE FUNCTION project_first_year(project project) RETURNS integer AS $$
  SELECT min(project_data_point.year) FROM public.project_data_point WHERE project_id = project.id
$$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION public.project_first_year(project) TO grff;

CREATE OR REPLACE FUNCTION project_last_year(project project) RETURNS integer AS $$
  SELECT max(project_data_point.year) FROM public.project_data_point WHERE project_id = project.id
$$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION public.project_last_year(project) TO grff;

CREATE OR REPLACE FUNCTION project_data_point_count(project project) RETURNS bigint AS $$
  SELECT count(project_data_point.id) FROM public.project_data_point WHERE project_id = project.id
$$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION public.project_data_point_count(project) TO grff;

CREATE INDEX project_data_point_project_id_idx ON public.project_data_point (project_id);

CREATE OR REPLACE FUNCTION public.get_producing_iso3166()
 RETURNS TABLE(iso3166 text, iso3166_2 text, en text, fr text, es text, sv text)
 LANGUAGE sql
 STABLE
AS $function$
SELECT DISTINCT prod.iso3166, prod.iso3166_2, c.en, c.fr, c.es, c.sv FROM
    (SELECT DISTINCT iso3166, COALESCE(iso3166_2, '') AS iso3166_2 FROM public.country_data_point WHERE data_type = 'production') prod
        JOIN public.country c ON c.iso3166 = prod.iso3166 AND c.iso3166_2 = prod.iso3166_2
ORDER BY prod.iso3166;
$function$;