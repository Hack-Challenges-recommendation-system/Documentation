-- The interaction log of the case dump in the import format of metric-service: one JSON array of
-- {userId, type, materialId, occurredAt, sessionId}. import.sh runs it against the restored case database and hands the
-- output to metric-service, which computes popularity and "taken after" signals from it.
--
-- The activity in the dump is about courses:
--   enrollment (CourseUserBindings)       → START: when the course was started, else the first lesson, else enrollment
--   completed enrollment                  → COMPLETE
--   lesson ratings, averaged per course   → LIKE when the average is 4 or more, DISLIKE when it is 2 or less
-- User ids stay the anonymized ids of the dump. Only courses that are in the catalog (published, live) count.

WITH courses AS (
    SELECT c."Id" FROM "Courses" c
    WHERE NOT c."IsDeleted" AND c."StatusId" = '61f12dbc-3cd4-4c14-b64b-1709548b904e'
),
enrollments AS (
    SELECT b."UserId" AS user_id, b."CourseId" AS course_id,
           coalesce(b."StudyingStartDate",
                    (SELECT min(l."Created") FROM "CourseUserLessonBindings" l WHERE l."CourseUserId" = b."Id"),
                    b."Created") AS started_at,
           CASE WHEN b."IsCompleted" THEN coalesce(b."Completed", b."Modified") END AS completed_at
    FROM "CourseUserBindings" b
    JOIN courses c ON c."Id" = b."CourseId"
    WHERE NOT b."IsDeleted" AND b."UserId" IS NOT NULL
),
ratings AS (
    SELECT r."UserId" AS user_id, cl."CourseId" AS course_id, avg(r."Value") AS value, max(r."Created") AS rated_at
    FROM "UserRatings" r
    JOIN "CourseLessonBindings" cl ON cl."LessonId" = r."EntityId"
    JOIN courses c ON c."Id" = cl."CourseId"
    WHERE r."UserId" IS NOT NULL
    GROUP BY r."UserId", cl."CourseId"
),
events AS (
    SELECT user_id, 'START' AS type, course_id, started_at AS occurred_at FROM enrollments WHERE started_at IS NOT NULL
    UNION ALL
    SELECT user_id, 'COMPLETE', course_id, completed_at FROM enrollments WHERE completed_at IS NOT NULL
    UNION ALL
    SELECT user_id, CASE WHEN value >= 4 THEN 'LIKE' ELSE 'DISLIKE' END, course_id, rated_at
    FROM ratings
    WHERE (value >= 4 OR value <= 2) AND rated_at IS NOT NULL
)
SELECT coalesce(json_agg(json_build_object(
           'userId', user_id::text,
           'type', type,
           'materialId', course_id::text,
           'occurredAt', to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'sessionId', NULL
       ) ORDER BY occurred_at, user_id, type), '[]'::json)
FROM events;
