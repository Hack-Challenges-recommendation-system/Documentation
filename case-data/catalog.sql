-- Materials of the case dump in the import format of catalog-service: one JSON array of
-- {id, title, summary, format, durationMinutes, level, topics, businessStages, spheres, paid, access, url}.
-- import.sh runs it against the restored case database and hands the output to catalog-service.
--
-- What becomes a material: live, published articles (public ones), documents, courses, webinars with a recording and
-- podcasts. Glossary terms, lessons and calculators are left out.
--
-- How the fields are filled:
--   url             https://kurs.alfabank.ru/<section>/<slug>/, the links the platform itself uses
--   title, summary  letters of the wrong script fixed ("бизнесe" → "бизнес"); the summary is the description
--                   without HTML, at most 400 characters
--   topics          the article rubric or document type, then the topics and tags of the content settings
--   businessStages  tag «Старт бизнеса» → IDEA, LAUNCH; tag «Развитие бизнеса» → GROWTH, SCALING; neither → none
--   level           industry «Без опыта» → BEGINNER, «С опытом» → ADVANCED
--   spheres         the industries that are lines of business, plus a rubric or topic with the same name
--   access          PURCHASE: bought separately (course type «Платный» or a cost);
--                   SUBSCRIPTION: part of a subscription (course type «По подписке», a subscription binding,
--                   a closed article); FREE otherwise. Courses.Cost = NULL means free, as the case experts said.
--   paid            access is not FREE, so catalog-service shows only the short benefit and the link

-- A run of letters that mixes Latin and Cyrillic ("бизнесe", "HoReСa") turns into the script of most of its letters.
CREATE FUNCTION pg_temp.fix_word(word text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN word !~ '[A-Za-z]' OR word !~ '[А-Яа-яЁё]' THEN word
        WHEN length(regexp_replace(word, '[^A-Za-z]', '', 'g')) > length(regexp_replace(word, '[^А-Яа-яЁё]', '', 'g'))
            THEN translate(word, 'АВСЕНКМОРТХаеорсху', 'ABCEHKMOPTXaeopcxy')
        ELSE translate(word, 'ABCEHKMOPTXaeopcxy', 'АВСЕНКМОРТХаеорсху')
    END
$$;

-- Letters of the wrong script in a text: mixed runs of letters are fixed one by one, so "UGC-контент" and "B2B" stay as
-- they are, and in a mostly Cyrillic text a one-letter Latin word ("важное o 115-ФЗ") turns Cyrillic.
CREATE FUNCTION pg_temp.fix_letters(value text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    WITH fixed AS (
        SELECT string_agg(pg_temp.fix_word(token[1]), '' ORDER BY n) AS text
        FROM regexp_matches(value, '[A-Za-zА-Яа-яЁё]+|[^A-Za-zА-Яа-яЁё]+', 'g') WITH ORDINALITY AS tokens(token, n)
    )
    SELECT CASE
        WHEN length(regexp_replace(text, '[^А-Яа-яЁё]', '', 'g')) > length(regexp_replace(text, '[^A-Za-z]', '', 'g'))
            THEN regexp_replace(regexp_replace(regexp_replace(regexp_replace(text,
                '(^|\s)o(?=\s|$)', '\1о', 'g'),
                '(^|\s)a(?=\s|$)', '\1а', 'g'),
                '(^|\s)c(?=\s|$)', '\1с', 'g'),
                '(^|\s)y(?=\s|$)', '\1у', 'g')
        ELSE text
    END
    FROM fixed
$$;

CREATE FUNCTION pg_temp.label(value text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(regexp_replace(btrim(pg_temp.fix_letters(replace(coalesce(value, ''), chr(160), ' '))), '\s+', ' ', 'g'), '')
$$;

-- Text of an HTML fragment: no tags, the common entities decoded, whitespace collapsed.
CREATE FUNCTION pg_temp.plain(html text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(regexp_replace(
        replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
            regexp_replace(coalesce(html, ''), '<[^>]*>', ' ', 'g'),
            '&nbsp;', ' '), '&#160;', ' '), '&laquo;', '«'), '&raquo;', '»'), '&mdash;', '—'), '&ndash;', '–'),
            '&quot;', '"'), '&lt;', '<'), '&gt;', '>'), '&hellip;', '…'), '&amp;', '&'),
        '[\s ]+', ' ', 'g')), '')
$$;

-- Cuts a text to the limit at a word boundary and marks the cut with an ellipsis.
CREATE FUNCTION pg_temp.cut(value text, max_length integer) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN value IS NULL OR length(value) <= max_length THEN value
        ELSE rtrim(regexp_replace(left(value, max_length - 1), '\s+\S*$', ''), ' ,.;:—–-') || '…'
    END
$$;

-- «1 час 15 минут» → 75, «4,5 часа» → 270, «10 минут» → 10.
CREATE FUNCTION pg_temp.minutes(value text) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(round(
        coalesce(replace(substring(value FROM '(\d+(?:[.,]\d+)?)\s*ч'), ',', '.')::numeric * 60, 0)
        + coalesce(substring(value FROM '(\d+)\s*мин')::numeric, 0)
    )::integer, 0)
$$;

WITH items AS (
    SELECT a."Id" AS id, 'ARTICLE' AS format, a."Title" AS title,
           coalesce(nullif(btrim(a."CardDescription"), ''), a."Description") AS description,
           a."Duration" AS duration, 'articles' AS section, a."Url" AS slug,
           CASE WHEN a."IsClosed" THEN 'SUBSCRIPTION' ELSE 'FREE' END AS access,
           s."Title" AS rubric
    FROM "Articles" a
    LEFT JOIN "ArticleSubjects" s ON s."Id" = a."SubjectId"
    WHERE NOT a."IsDeleted" AND a."IsPublic" AND a."StatusId" = '61f12dbc-3cd4-4c14-b64b-1709548b904e'

    UNION ALL
    SELECT d."Id", 'TEMPLATE', d."Title", d."Description", NULL, 'documents', d."Url", 'FREE', t."Title"
    FROM "Documents" d
    LEFT JOIN "DocumentTypes" t ON t."Id" = d."TypeId"
    WHERE NOT d."IsDeleted" AND d."StatusId" = '61f12dbc-3cd4-4c14-b64b-1709548b904e'

    UNION ALL
    SELECT c."Id", 'COURSE', c."Title", c."Description", c."Duration", 'courses', c."Url",
           CASE
               WHEN coalesce(c."Cost", 0) > 0 OR t."Title" = 'Платный' THEN 'PURCHASE'
               WHEN t."Title" = 'По подписке'
                    OR EXISTS (SELECT 1 FROM "CourseSubscriptions" cs WHERE cs."CourseId" = c."Id") THEN 'SUBSCRIPTION'
               ELSE 'FREE'
           END,
           NULL
    FROM "Courses" c
    LEFT JOIN "CourseTypes" t ON t."Id" = c."TypeId"
    WHERE NOT c."IsDeleted" AND c."StatusId" = '61f12dbc-3cd4-4c14-b64b-1709548b904e'

    UNION ALL
    SELECT w."Id", 'WEBINAR', w."Title", w."Description", w."Duration", 'webinars', w."Url", 'FREE', NULL
    FROM "Webinars" w
    WHERE NOT w."IsDeleted" AND w."StatusId" = '61f12dbc-3cd4-4c14-b64b-1709548b904e' AND w."VideoId" IS NOT NULL

    UNION ALL
    SELECT p."Id", 'PODCAST', p."Title", p."Description", p."Duration", 'podcasts', p."Url",
           CASE
               WHEN coalesce(p."Cost", 0) > 0 THEN 'PURCHASE'
               WHEN EXISTS (SELECT 1 FROM "PodcastSubscriptions" ps WHERE ps."PodcastId" = p."Id") THEN 'SUBSCRIPTION'
               ELSE 'FREE'
           END,
           NULL
    FROM "Podcasts" p
    WHERE NOT p."IsDeleted" AND p."StatusId" = '61f12dbc-3cd4-4c14-b64b-1709548b904e'
),
settings AS (
    SELECT cs."Id", cs."EntityId" FROM "ContentSettings" cs WHERE NOT cs."IsDeleted"
),
-- Rubric first, then topics, then tags, each in the order the platform gives them.
labels AS (
    SELECT i.id, pg_temp.label(i.rubric) AS label, 0 AS kind, 0 AS position FROM items i
    UNION ALL
    SELECT s."EntityId", pg_temp.label(t."Title"), 1, coalesce(st."Order", 0)
    FROM settings s
    JOIN "ContentSettingsTopics" st ON st."ContentSettingsId" = s."Id"
    JOIN "Topics" t ON t."Id" = st."TopicId" AND NOT t."IsDeleted"
    UNION ALL
    SELECT s."EntityId", pg_temp.label(g."Title"), 2, coalesce(sg."Order", 0)
    FROM settings s
    JOIN "ContentSettingsTags" sg ON sg."ContentSettingsId" = s."Id"
    JOIN "Tags" g ON g."Id" = sg."TagId" AND NOT g."IsDeleted"
),
topics AS (
    SELECT id, array_agg(label ORDER BY kind, position, label) AS topics
    FROM (
        SELECT DISTINCT ON (id, lower(label)) id, label, kind, position
        FROM labels
        WHERE label IS NOT NULL AND label NOT IN ('Старт бизнеса', 'Развитие бизнеса')
        ORDER BY id, lower(label), kind, position
    ) unique_labels
    GROUP BY id
),
stages AS (
    SELECT id, array_agg(stage ORDER BY array_position(ARRAY['IDEA', 'LAUNCH', 'GROWTH', 'SCALING'], stage)) AS stages
    FROM (
        SELECT DISTINCT l.id, stage
        FROM labels l
        CROSS JOIN LATERAL unnest(CASE l.label
            WHEN 'Старт бизнеса' THEN ARRAY['IDEA', 'LAUNCH']
            WHEN 'Развитие бизнеса' THEN ARRAY['GROWTH', 'SCALING']
        END) AS stage
        WHERE l.kind = 2
    ) unique_stages
    GROUP BY id
),
industries AS (
    SELECT s."EntityId" AS id, pg_temp.label(i."Title") AS label, coalesce(si."Order", 0) AS position
    FROM settings s
    JOIN "ContentSettingsIndustries" si ON si."ContentSettingsId" = s."Id"
    JOIN "Industries" i ON i."Id" = si."IndustryId" AND NOT i."IsDeleted"
),
lines_of_business AS (
    SELECT pg_temp.label(unnest(ARRAY[
        'HoReСa', 'Розница', 'Услуги', 'ECom', 'Marketplace', 'Производство', 'Оптовая торговля', 'B2B', 'B2G',
        'Строительство и недвижимость', 'Транспорт и логистика', 'Финансы и страхование', 'Бухгалтерия'
    ])) AS label
),
spheres AS (
    SELECT id, array_agg(label ORDER BY position, label) AS spheres
    FROM (
        SELECT DISTINCT ON (id, label) id, label, position
        FROM (
            SELECT id, label, position FROM industries
            UNION ALL
            SELECT id, label, 1000 FROM labels WHERE kind IN (0, 1)
        ) candidates
        WHERE label IN (SELECT label FROM lines_of_business)
        ORDER BY id, label, position
    ) unique_spheres
    GROUP BY id
),
levels AS (
    SELECT id,
           CASE
               WHEN bool_or(label = 'Без опыта') THEN 'BEGINNER'
               WHEN bool_or(label = 'С опытом') THEN 'ADVANCED'
           END AS level
    FROM industries
    GROUP BY id
)
SELECT coalesce(json_agg(json_build_object(
           'id', i.id::text,
           'title', left(pg_temp.label(i.title), 300),
           'summary', pg_temp.cut(pg_temp.fix_letters(pg_temp.plain(i.description)), 400),
           'format', i.format,
           'durationMinutes', pg_temp.minutes(i.duration),
           'level', lv.level,
           'topics', coalesce(t.topics, ARRAY[]::text[]),
           'businessStages', coalesce(st.stages, ARRAY[]::text[]),
           'spheres', coalesce(sp.spheres, ARRAY[]::text[]),
           'paid', i.access <> 'FREE',
           'access', i.access,
           'url', 'https://kurs.alfabank.ru/' || i.section || '/' || btrim(i.slug, '/ ') || '/'
       ) ORDER BY i.format, i.id), '[]'::json)
FROM items i
LEFT JOIN topics t ON t.id = i.id
LEFT JOIN stages st ON st.id = i.id
LEFT JOIN spheres sp ON sp.id = i.id
LEFT JOIN levels lv ON lv.id = i.id
WHERE nullif(btrim(i.title), '') IS NOT NULL AND nullif(btrim(i.slug, '/ '), '') IS NOT NULL;
