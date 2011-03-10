-- sql/1283212129-json_data.sql SQL Migration

SET client_min_messages TO warning;
SET log_min_messages    TO warning;

BEGIN;

CREATE OR REPLACE FUNCTION munge_email(
    email EMAIL
) RETURNS TEXT LANGUAGE plpgsql IMMUTABLE STRICT AS $$
/*

    % SELECT munge_email('foo@bar.com');
     munge_email 
    ─────────────
     bar.com|foo

Munges an email address. This is for use in `mirrors.json`, just to have a bit
of obfuscation. All it does is move the username to the end, separated from
the domain name by a pipe. So "foo@bar.com" becomes "bar.com|foo".

*/
BEGIN
    RETURN split_part(email, '@', 2) || '|' || split_part(email, '@', 1);
END;
$$;

CREATE OR REPLACE FUNCTION get_mirrors_json(
) RETURNS TEXT LANGUAGE sql STABLE STRICT AS $$
/*

    % SELECT get_mirrors_json();
                    get_mirrors_json                 
    ─────────────────────────────────────────────────
     [                                              ↵
        {                                           ↵
           "uri": "http://example.com/pgxn/",       ↵
           "frequency": "hourly",                   ↵
           "location": "Portland, OR, USA",         ↵
           "organization": "Kineticode, Inc.",      ↵
           "timezone": "America/Los_Angeles",       ↵
           "email": "example.com|pgxn",             ↵
           "bandwidth": "10MBps",                   ↵
           "src": "rsync://master.pgxn.org/pgxn/"   ↵
        },                                          ↵
        {                                           ↵
           "uri": "http://pgxn.example.net/",       ↵
           "frequency": "daily",                    ↵
           "location": "Portland, OR, USA",         ↵
           "organization": "David E. Wheeler",      ↵
           "timezone": "America/Los_Angeles",       ↵
           "email": "example.net|pgxn",             ↵
           "bandwidth": "Cable",                    ↵
           "src": "rsync://master.pgxn.org/pgxn/",  ↵
           "rsync": "rsync://master.pgxn.org/pgxn/",↵
           "notes": "These be some notes, yo"       ↵
        }                                           ↵
     ]                                              ↵

Returns the JSON for the `mirrors.json` file. The format is an array of JSON
objects. All the required fields will be present, and the optional fields
"rsync" and "notes" will be present only if they have values.

*/
    SELECT E'[\n   ' || array_to_string(ARRAY(
        SELECT E'{\n      ' || array_to_string(ARRAY[
            json_key('uri')          || ': ' || json_value(uri),
            json_key('frequency')    || ': ' || json_value(frequency),
            json_key('location')     || ': ' || json_value(location),
            json_key('organization') || ': ' || json_value(organization),
            json_key('timezone')     || ': ' || json_value(timezone),
            json_key('email')        || ': ' || json_value(munge_email(email)),
            json_key('bandwidth')    || ': ' || json_value(bandwidth),
            json_key('src')          || ': ' || json_value(src),
            json_key('rsync')        || ': ' || json_value(rsync, NULL),
            json_key('notes')        || ': ' || json_value(notes, NULL)
        ], E',\n      '
        ) || E'\n   }' FROM mirrors
         ORDER BY created_at
    ), E',\n   ') || E'\n]\n';
$$;

CREATE OR REPLACE FUNCTION by_extension_json(
   dist      TEXT,
   version   SEMVER
) RETURNS TABLE (
    extension CITEXT,
    json      TEXT
) LANGUAGE plpgsql STABLE STRICT AS $$
/*

    % SELECT * FROM by_extension_json('pair', '1.2.0');
     extension │                                 json                                 
    ───────────┼──────────────────────────────────────────────────────────────────────
     pair      │ {                                                                   ↵
               │    "extension": "pair",                                             ↵
               │    "latest": "testing",                                             ↵
               │    "stable": { "dist": "pair", "version": "1.0.0" },                ↵
               │    "testing": { "dist": "pair", "version": "1.2.0" },               ↵
               │    "distributions": {                                               ↵
               │       "1.2.0": [                                                    ↵
               │          { "dist": "pair", "version": "1.2.0", "status": "testing" }↵
               │       ],                                                            ↵
               │       "1.0.0": [                                                    ↵
               │          { "dist": "pair", "version": "1.0.0" }                     ↵
               │       ],                                                            ↵
               │       "0.2.2": [                                                    ↵
               │          { "dist": "pair", "version": "0.0.1", "status": "testing" }↵
               │       ]                                                             ↵
               │    }                                                                ↵
               │ }                                                                   ↵
               │ 
     trip      │ {                                                                   ↵
               │    "extension": "trip",                                             ↵
               │    "latest": "testing",                                             ↵
               │    "stable": { "dist": "pair", "version": "1.0.0" },                ↵
               │    "testing": { "dist": "pair", "version": "1.2.0" },               ↵
               │    "distributions": {                                               ↵
               │       "0.9.10": [                                                   ↵
               │          { "dist": "pair", "version": "1.2.0", "status": "testing" }↵
               │       ],                                                            ↵
               │       "0.9.9": [                                                    ↵
               │          { "dist": "pair", "version": "1.0.0" }                     ↵
               │       ],                                                            ↵
               │       "0.2.1": [                                                    ↵
               │          { "dist": "pair", "version": "0.0.1", "status": "testing" }↵
               │       ]                                                             ↵
               │    }                                                                ↵
               │ }                                                                   ↵
               │ 

Returns a set of extensions and their JSON metadata for a given distribution
version. In the above example, the "pair" and "trip" extensions are both in
the "pair 1.0.0" distribution. Each has data indicating its latest stable,
testing, and unstable versions (as appropriate) and the distribution details
for every released version in descending by extension version number.

*/
DECLARE
    latest   TEXT;
    stable   TEXT;
    testing  TEXT;
    unstable TEXT;
    ext      TEXT;
    prev     TEXT;
    extv     TEXT;
    distjson TEXT[] := '{}';
    dists    HSTORE[];
    dist     HSTORE;
BEGIN
    FOR ext, extv, dists IN
        SELECT de.extension, de.ext_version,
               array_agg(hstore(ARRAY[
                   'dist',      d.name,
                   'version',   d.version::text,
                   'relstatus', d.relstatus::text
               ]) ORDER BY d.created_at DESC)
          FROM distribution_extensions de
          JOIN distributions d
            ON de.distribution = d.name
           AND de.dist_version = d.version
         WHERE de.extension IN (
             SELECT distribution_extensions.extension
               FROM distribution_extensions
              WHERE distribution = $1
                AND dist_version = $2
         )
         GROUP BY de.extension, de.ext_version
         UNION SELECT NULL, NULL, NULL
         ORDER BY extension, ext_version USING >
    LOOP
        IF (prev IS NOT NULL AND prev <> ext) OR ext IS NULL THEN
            extension := prev;
            json := E'{\n   "extension": ' || json_value(prev)
                 || E',\n   "latest": ' || json_value(latest)
                 || COALESCE(E',\n   "stable":'   || stable, '')
                 || COALESCE(E',\n   "testing":'  || testing, '')
                 || COALESCE(E',\n   "unstable":' || unstable, '')
                 || E',\n   "versions": {\n' || array_to_string(distjson, E',\n')
                 || E'\n   }\n}\n';
            RETURN NEXT;
            latest   := NULL;
            stable   := NULL;
            testing  := NULL;
            unstable := NULL;
            distjson := '{}';
            IF ext IS NULL THEN EXIT; END IF;
        END IF;
        prev := ext;
        DECLARE
            myjson TEXT[] := '{}';
        BEGIN
            FOR dist IN SELECT * FROM unnest(dists) LOOP
                myjson := array_append(myjson,
                          '         { "dist": ' || json_value(dist->'dist')
                       || ', "version": ' || json_value(dist->'version')
                       || CASE dist->'relstatus'
                              WHEN 'stable' THEN ''
                              ELSE ', "status": ' || json_value(dist->'relstatus')
                          END
                       || E' }');
                IF latest IS NULL THEN latest := dist->'relstatus'; END IF;
                CASE dist->'relstatus'
                    WHEN 'stable' THEN IF stable IS NULL THEN
                        stable := ' { "dist": ' || json_value(dist->'dist')
                        || ', "version": ' || json_value(dist->'version') || ' }';
                    END IF;
                    WHEN 'testing' THEN IF testing IS NULL THEN
                        testing := ' { "dist": ' || json_value(dist->'dist')
                        || ', "version": ' || json_value(dist->'version') || ' }';
                    END IF;
                    WHEN 'unstable' THEN IF unstable IS NULL THEN
                        unstable := ' { "dist": ' || json_value(dist->'dist')
                        || ', "version": ' || json_value(dist->'version') || ' }';
                    END IF;
                END CASE;
            END LOOP;
            distjson := array_append(distjson, E'      ' || json_key(extv) || E': [\n'
                     || array_to_string(myjson, E',\n') || E'\n      ]');
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION by_dist_json(
   dist      TEXT
) RETURNS TEXT LANGUAGE sql STABLE STRICT AS $$
/*

    % SELECT * FROM by_dist_json('pair');
                              by_dist_json                          
    ────────────────────────────────────────────────────────────────
     {                                                             ↵
        "name": "pair",                                            ↵
        "releases": {                                              ↵
           "stable": [                                             ↵
              {"version": "0.1.1", "date": "2010-10-29T22:44:42Z"},↵
              {"version": "0.1.0", "date": "2010-10-19T03:59:54Z"} ↵
           ]                                                       ↵
        }                                                          ↵
     }                                                             ↵

Returns a JSON string describing a distribution, including all of its released
versions and their dates.

*/
    SELECT E'{\n   "name": ' || json_value(distribution)
           || E',\n   "releases": {\n      '
           || array_to_string(ARRAY[
               '"stable": '   || stable,
               '"testing": '  || testing,
               '"unstable": ' || unstable
           ], E',\n      ') || E'\n   }\n}\n'
      FROM (
        SELECT name AS distribution,
           E'[\n         ' || string_agg(
               CASE relstatus WHEN 'stable'
               THEN '{"version": "' || version
                 || '", "date": "' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}'
               ELSE NULL
           END, E',\n         ' ORDER BY version DESC) || E'\n      ]' AS stable,
           E'[\n         ' || string_agg(
               CASE relstatus
               WHEN 'testing'
               THEN '{"version": "' || version
                 || '", "date": "' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}'
               ELSE NULL
           END, E',\n         ' ORDER BY version DESC) || E'\n      ]' AS testing,
           E'[\n         ' || string_agg(
               CASE relstatus
               WHEN 'unstable'
               THEN '{"version": "' || version
                 || '", "date": "' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}'
               ELSE NULL
           END, E',\n         ' ORDER BY version DESC) || E'\n      ]' AS unstable
          FROM distributions
         GROUP BY name
      ) AS dv
     WHERE distribution = $1;
$$;

CREATE OR REPLACE FUNCTION by_tag_json(
   dist      TEXT,
   version   SEMVER
) RETURNS TABLE (
    tag  CITEXT,
    json TEXT
) LANGUAGE sql STABLE STRICT AS $$
/*

    % SELECT * FROM by_tag_json('pair', '0.1.0');
            tag        │                               json                                
    ───────────────────┼───────────────────────────────────────────────────────────────────
     key value         │ {                                                                ↵
                       │    "tag": "key value",                                           ↵
                       │    "releases": {                                                 ↵
                       │       "pair": {                                                  ↵
                       │          "stable": [                                             ↵
                       │             {"version": "0.1.1", "date": "2010-10-29T22:44:42Z"} ↵
                       │          ]                                                       ↵
                       │       },                                                         ↵
                       │       "trip": {                                                  ↵
                       │          "stable": [                                             ↵
                       │             {"version": "0.0.1", "date": "2010-09-25T15:48:39Z"} ↵
                       │          ]                                                       ↵
                       │       }                                                          ↵
                       │    }                                                             ↵
                       │ }                                                                ↵
                       │ 
     ordered pair      │ {                                                                ↵
                       │    "tag": "ordered pair",                                        ↵
                       │    "releases": {                                                 ↵
                       │       "pair": {                                                  ↵
                       │          "stable": [                                             ↵
                       │             {"version": "0.1.1", "date": "2010-10-29T22:44:42Z"},↵
                       │             {"version": "0.1.0", "date": "2010-10-19T03:59:54Z"} ↵
                       │          ],                                                      ↵
                       │          "testing": [                                            ↵
                       │             {"version": "0.0.5", "date": "2010-10-10T14:35:18Z"} ↵
                       │          ]                                                       ↵
                       │       }                                                          ↵
                       │    }                                                             ↵
                       │ }                                                                ↵
                       │ 

For a given distribution and version, returns a set of tags and the JSON to
describe them. In this example, pair 0.1.0 has two tags. The tag "key value "
is associated with pgtap 0.1.1 and trip 0.0.1. The tag "ordered pair", on the
other hand, is associcated with three versions of the "pair" distribution, as
well.

*/
    WITH td AS (
        WITH ds AS (
            WITH dt AS (
                SELECT dt.tag, dt.distribution, d.version, d.relstatus
                  FROM distribution_tags dt
                  JOIN distributions d
                    ON dt.distribution = d.name
                   AND dt.version      = d.version
                 WHERE dt.tag IN (
                    SELECT tag
                      FROM distribution_tags
                     WHERE distribution = $1
                       AND version      = $2
                 )
             )
             SELECT dt.tag, dt.distribution, d.relstatus,
                    array_agg('{"version": "' || d.version || '", "date": "' || to_char(d.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}' ORDER BY d.version DESC) AS versions
               FROM dt
               JOIN distributions d
                 ON dt.distribution = d.name
                AND dt.version      = d.version
             GROUP BY tag, dt.distribution, d.relstatus
        )
        SELECT tag, distribution,
               array_agg(
                   json_key(relstatus::text)
                   || E': [\n            '
                   || array_to_string(versions, E',\n            ')
                   || E'\n         ]') AS relv
          FROM ds
         GROUP BY tag, distribution
    )
    SELECT LOWER(tag)::CITEXT, E'{\n   "tag": ' || json_value(tag) || E',\n   "releases": {\n      '
        || string_agg(json_key(distribution) || E': {\n         '
        || array_to_string(relv, E',\n         '), E'\n      },\n      ')
        || E'\n      }\n   }\n}\n'
      FROM td
     GROUP BY tag;
$$;

CREATE OR REPLACE FUNCTION by_user_json(
   nickname LABEL
) RETURNS TEXT LANGUAGE sql STABLE STRICT AS $$
/*

    % SELECT by_user_json('theory');
                               by_user_json
    ───────────────────────────────────────────────────────────────────
     {                                                                ↵
        "nickname": "theory",                                         ↵
        "name": "David E. Wheeler",                                   ↵
        "email": "david@justatheory.com",                             ↵
        "uri": "http://justatheory.com/",                             ↵
        "twitter": "theory",                                          ↵
        "releases": {                                                 ↵
           "pair": {                                                  ↵
              "stable": [                                             ↵
                 {"version": "0.1.1", "date": "2010-10-29T22:44:42Z"},↵
                 {"version": "0.1.0", "date": "2010-10-19T03:59:54Z"} ↵
              ]                                                       ↵
           },                                                         ↵
           "pgTAP": {                                                 ↵
              "stable": [                                             ↵
                 {"version": "0.25.0", "date": "2011-02-02T03:25:17Z"}↵
              ]                                                       ↵
           }                                                          ↵
        }                                                             ↵
     }                                                                ↵

Returns a JSON string describing the given user, including all versions and
release dates of the distributions the user owns. The included distribution
versions are only the versions owned by the user; if someone else uploaded a
different version of the distribution, that version will not be owned by this
user and thus not included in the JSON.

*/
    WITH dv AS (
        SELECT name AS distribution, creator,
           E'[\n            ' || string_agg(
               CASE relstatus WHEN 'stable'
               THEN '{"version": "' || version
                 || '", "date": "' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}'
               ELSE NULL
           END, E',\n            ' ORDER BY version DESC) || E'\n         ]' AS stable,
           E'[\n            ' || string_agg(
               CASE relstatus
               WHEN 'testing'
               THEN '{"version": "' || version
                 || '", "date": "' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}'
               ELSE NULL
           END, E',\n            ' ORDER BY version DESC) || E'\n         ]' AS testing,
           E'[\n            ' || string_agg(
               CASE relstatus
               WHEN 'unstable'
               THEN '{"version": "' || version
                 || '", "date": "' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '"}'
               ELSE NULL
           END, E',\n            ' ORDER BY version DESC) || E'\n         ]' AS unstable
         FROM distributions
        GROUP BY name, creator
    )
    SELECT E'{\n   ' || array_to_string(ARRAY[
        '"nickname": ' || json_value(u.nickname),
        '"name": '     || json_value(u.full_name),
        '"email": '    || json_value(u.email),
        '"uri": '      || json_value(uri, NULL),
        '"twitter": '  || json_value(CASE u.twitter WHEN '' THEN NULL ELSE u.twitter END, NULL)
    ], E',\n   ') || COALESCE(E',\n   "releases": {\n' ||
           string_agg(
                 '      "' || dv.distribution
                   || E'": {\n         ' ||  array_to_string(ARRAY[
                       '"stable": '   || stable,
                       '"testing": '  || testing,
                       '"unstable": ' || unstable
                   ], E',\n         ') || E'\n      }',
              E',\n')
           || E'\n   }\n}\n', E'\n}\n')
      FROM users u
      LEFT JOIN dv ON u.nickname = dv.creator
     WHERE u.nickname = $1
     GROUP BY u.nickname, u.full_name, u.email, u.uri, u.twitter;
$$;

COMMIT;
