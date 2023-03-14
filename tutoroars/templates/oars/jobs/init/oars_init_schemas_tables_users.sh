echo "Install clickhouse-client..."
apt-get install -y apt-transport-https ca-certificates dirmngr
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 8919F6BD2B48D754

echo "deb https://packages.clickhouse.com/deb stable main" | tee \
    /etc/apt/sources.list.d/clickhouse.list
apt-get update

apt-get install -y clickhouse-client

echo "Running schema creation scripts..."
clickhouse client --user "{{ CLICKHOUSE_ADMIN_USER }}" --password="{{ CLICKHOUSE_ADMIN_PASSWORD }}" --host "{{ CLICKHOUSE_HOST }}" --port {{ CLICKHOUSE_PORT }} --multiquery <<'EOF'
-- Allow JSON fields
SET allow_experimental_object_type=1;

-- Create various non-admin users reporting users
CREATE USER IF NOT EXISTS {{ OARS_CLICKHOUSE_LRS_USER}} IDENTIFIED WITH sha256_password BY '{{ OARS_CLICKHOUSE_LRS_PASSWORD }}';
CREATE USER IF NOT EXISTS {{ OARS_CLICKHOUSE_REPORT_USER}} IDENTIFIED WITH sha256_password BY '{{ OARS_CLICKHOUSE_REPORT_PASSWORD }}';
CREATE USER IF NOT EXISTS {{ OARS_CLICKHOUSE_CMS_USER}} IDENTIFIED WITH sha256_password BY '{{ OARS_CLICKHOUSE_CMS_PASSWORD }}';

-- Update user passwords if they do exist
ALTER USER {{ OARS_CLICKHOUSE_LRS_USER}} IDENTIFIED WITH sha256_password BY '{{ OARS_CLICKHOUSE_LRS_PASSWORD }}';
ALTER USER {{ OARS_CLICKHOUSE_REPORT_USER}} IDENTIFIED WITH sha256_password BY '{{ OARS_CLICKHOUSE_REPORT_PASSWORD }}';
ALTER USER {{ OARS_CLICKHOUSE_CMS_USER}} IDENTIFIED WITH sha256_password BY '{{ OARS_CLICKHOUSE_CMS_PASSWORD }}';


-- Create the xapi schema if it doesn't exist
CREATE DATABASE IF NOT EXISTS {{ OARS_XAPI_DATABASE }};

-- Raw table that Ralph writes to
CREATE TABLE IF NOT EXISTS {{ OARS_XAPI_DATABASE }}.{{ OARS_RAW_XAPI_TABLE }}  (
    event_id UUID NOT NULL,
    emission_time DateTime64(6) NOT NULL,
    event JSON NOT NULL,
    event_str String NOT NULL
) ENGINE MergeTree
ORDER BY (emission_time, event_id)
PRIMARY KEY (emission_time, event_id);

-- Processed table that Superset reads from
CREATE TABLE IF NOT EXISTS {{ OARS_XAPI_DATABASE }}.{{ OARS_XAPI_TABLE }} (
    event_id UUID NOT NULL,
    verb_id String NOT NULL,
    actor_id UUID NOT NULL,
    org String NOT NULL,
    course_id String NOT NULL,
    emission_time DateTime64(6) NOT NULL,
    event JSON NOT NULL
) ENGINE MergeTree
ORDER BY (org, course_id, verb_id, actor_id, emission_time, event_id)
PRIMARY KEY (org, course_id, verb_id, actor_id, emission_time, event_id);

-- Materialized view that moves data from the raw table to processed table
CREATE MATERIALIZED VIEW IF NOT EXISTS {{ OARS_XAPI_DATABASE }}.{{ OARS_XAPI_TRANSFORM_MV }}
    TO {{ OARS_XAPI_DATABASE }}.{{ OARS_XAPI_TABLE }} AS
    SELECT
    event_id as event_id,
    JSON_VALUE(event_str, '$.verb.id') as verb_id,
    JSON_VALUE(event_str, '$.actor.account.name') as actor_id,
    -- If the contextActivities parent is a course, use that. Otherwise use the object id for the course id
    if(
        JSON_VALUE(
            event_str,
            '$.context.contextActivities.parent[0].definition.type')
                = 'http://adlnet.gov/expapi/activities/course',
            JSON_VALUE(event_str, '$.context.contextActivities.parent[0].id'),
            JSON_VALUE(event_str, '$.object.id')
        ) as course_id,
    emission_time as emission_time,
    event as event
    FROM {{ OARS_XAPI_DATABASE }}.{{ OARS_RAW_XAPI_TABLE }};


-- Create the coursegraph schema if it doesn't exist
CREATE DATABASE IF NOT EXISTS {{ OARS_COURSEGRAPH_DATABASE }};
CREATE TABLE IF NOT EXISTS {{ OARS_COURSEGRAPH_DATABASE }}.{{ OARS_COURSEGRAPH_NODES_TABLE }}
(
    org              String,
    course_key       String,
    course           String,
    run              String,
    location         String,
    display_name     String,
    block_type       String,
    detached         Bool,
    edited_on        String,
    time_last_dumped String,
    order            Int32 default 0
) engine = MergeTree
    PRIMARY KEY (course_key, location)
    ORDER BY (course_key, location);

CREATE TABLE IF NOT EXISTS {{ OARS_COURSEGRAPH_DATABASE }}.{{ OARS_COURSEGRAPH_RELATIONSHIPS_TABLE }}
(
    course_key      String,
    parent_location String,
    child_location  String,
    order           Int32
) engine = MergeTree
    PRIMARY KEY (course_key, parent_location, child_location, order)
    ORDER BY (course_key, parent_location, child_location, order);


-- Grant permissions to the users
GRANT INSERT, SELECT ON {{ OARS_XAPI_DATABASE }}.* TO '{{ OARS_CLICKHOUSE_LRS_USER }}';
GRANT SELECT ON {{ OARS_XAPI_DATABASE }}.* TO '{{ OARS_CLICKHOUSE_REPORT_USER }}';

GRANT INSERT, SELECT ON {{ OARS_COURSEGRAPH_DATABASE }}.* TO '{{ OARS_CLICKHOUSE_CMS_USER }}';
GRANT SELECT ON {{ OARS_COURSEGRAPH_DATABASE }}.* TO '{{ OARS_CLICKHOUSE_REPORT_USER }}';

EOF

echo "Replacing demo coursegrah data ..."
clickhouse client --user "{{ CLICKHOUSE_ADMIN_USER }}" --password="{{ CLICKHOUSE_ADMIN_PASSWORD }}" --host "{{ CLICKHOUSE_HOST }}" --port {{ CLICKHOUSE_PORT }} --allow_experimental_lightweight_delete=1 -q "DELETE FROM {{ OARS_COURSEGRAPH_DATABASE }}.{{ OARS_COURSEGRAPH_NODES_TABLE }} WHERE course_key = 'course-v1:edX+DemoX+Demo_Course'";

clickhouse client --user "{{ CLICKHOUSE_ADMIN_USER }}" --password="{{ CLICKHOUSE_ADMIN_PASSWORD }}" --host "{{ CLICKHOUSE_HOST }}" --port {{ CLICKHOUSE_PORT }} --allow_experimental_lightweight_delete=1 -q "DELETE FROM {{ OARS_COURSEGRAPH_DATABASE }}.{{ OARS_COURSEGRAPH_NODES_TABLE }} WHERE course_key = 'course-v1:edX+DemoX+Demo_Course'";

clickhouse client --user "{{ CLICKHOUSE_ADMIN_USER }}" --password="{{ CLICKHOUSE_ADMIN_PASSWORD }}" --host "{{ CLICKHOUSE_HOST }}" --port {{ CLICKHOUSE_PORT }} --query "INSERT INTO {{ OARS_COURSEGRAPH_DATABASE }}.{{ OARS_COURSEGRAPH_NODES_TABLE }} FORMAT CSV" \
  < /app/oars/data/clickhouse/coursegraph_nodes.csv;

clickhouse client --user "{{ CLICKHOUSE_ADMIN_USER }}" --password="{{ CLICKHOUSE_ADMIN_PASSWORD }}" --host "{{ CLICKHOUSE_HOST }}" --port {{ CLICKHOUSE_PORT }} --query "INSERT INTO {{ OARS_COURSEGRAPH_DATABASE }}.{{ OARS_COURSEGRAPH_RELATIONSHIPS_TABLE }} FORMAT CSV" \
  < /app/oars/data/clickhouse/coursegraph_relationships.csv;
