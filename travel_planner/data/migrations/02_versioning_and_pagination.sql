-- Versioning and pagination support for travel plans

-- Add version tracking to travel plans
ALTER TABLE travel_plans
ADD COLUMN IF NOT EXISTS version INTEGER DEFAULT 1,
ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES travel_plans(id) NULL;

-- Create indexes for version and parent_id
CREATE INDEX IF NOT EXISTS idx_travel_plans_version
ON travel_plans(version);

CREATE INDEX IF NOT EXISTS idx_travel_plans_parent_id
ON travel_plans(parent_id);

-- Add modification reason for tracking changes between versions
ALTER TABLE travel_plans
ADD COLUMN IF NOT EXISTS modification_reason TEXT NULL;

-- Create a function to create a new version of a travel plan
CREATE OR REPLACE FUNCTION create_travel_plan_version(
    plan_id UUID,
    modification_reason TEXT,
    updates JSONB
) RETURNS UUID AS $$
DECLARE
    old_plan JSONB;
    new_plan JSONB;
    new_plan_id UUID;
    current_version INTEGER;
BEGIN
    -- Get the current plan data and version
    SELECT
        jsonb_build_object(
            'user_id', user_id,
            'travel_query_id', travel_query_id,
            'destination', destination,
            'flights', flights,
            'accommodation', accommodation,
            'transportation', transportation,
            'activities', activities,
            'budget', budget,
            'overview', overview,
            'recommendations', recommendations,
            'alerts', alerts,
            'metadata', metadata
        ),
        version
    INTO old_plan, current_version
    FROM travel_plans
    WHERE id = plan_id;

    IF old_plan IS NULL THEN
        RAISE EXCEPTION 'Travel plan with ID % not found', plan_id;
    END IF;

    -- Merge updates with old plan data
    new_plan := old_plan || updates;

    -- Insert the new version
    INSERT INTO travel_plans (
        user_id,
        travel_query_id,
        destination,
        flights,
        accommodation,
        transportation,
        activities,
        budget,
        overview,
        recommendations,
        alerts,
        metadata,
        parent_id,
        version,
        modification_reason
    )
    VALUES (
        (new_plan->>'user_id')::UUID,
        (new_plan->>'travel_query_id')::UUID,
        new_plan->'destination',
        new_plan->'flights',
        new_plan->'accommodation',
        new_plan->'transportation',
        new_plan->'activities',
        new_plan->'budget',
        new_plan->>'overview',
        new_plan->'recommendations',
        new_plan->'alerts',
        new_plan->'metadata',
        plan_id,
        current_version + 1,
        modification_reason
    )
    RETURNING id INTO new_plan_id;

    RETURN new_plan_id;
END;
$$ LANGUAGE plpgsql;

-- Create a function to get a plan and its descendant versions
CREATE OR REPLACE FUNCTION get_travel_plan_history(root_plan_id UUID)
RETURNS TABLE(
    id UUID,
    version INTEGER,
    parent_id UUID,
    modification_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE plan_hierarchy AS (
        -- Start with the supplied plan
        SELECT
            tp.id,
            tp.parent_id,
            tp.version,
            tp.modification_reason,
            tp.created_at
        FROM travel_plans AS tp
        WHERE tp.id = root_plan_id

        UNION ALL

        -- Find its descendant versions
        SELECT
            tp.id,
            tp.parent_id,
            tp.version,
            tp.modification_reason,
            tp.created_at
        FROM travel_plans AS tp
        JOIN plan_hierarchy AS ph
            ON tp.parent_id = ph.id
    )
    SELECT
        ph.id,
        ph.version,
        ph.parent_id,
        ph.modification_reason,
        ph.created_at
    FROM plan_hierarchy AS ph
    ORDER BY ph.version;
END;
$$ LANGUAGE plpgsql;

-- Create a view for travel plan summaries with pagination metadata
CREATE OR REPLACE VIEW travel_plans_paginated AS
SELECT
    tp.id,
    tp.user_id,
    tp.travel_query_id,
    tp.destination->>'name' AS destination_name,
    tp.destination->>'country' AS destination_country,
    tp.version,
    tp.parent_id,
    tp.modification_reason,
    tq.departure_date,
    tq.return_date,
    tq.travelers,
    tp.budget->>'total_cost' AS total_cost,
    tp.created_at,
    tp.updated_at,
    LEAD(tp.id) OVER (
        PARTITION BY tp.user_id
        ORDER BY tp.created_at DESC
    ) AS next_cursor,
    LAG(tp.id) OVER (
        PARTITION BY tp.user_id
        ORDER BY tp.created_at DESC
    ) AS prev_cursor,
    COUNT(*) OVER (
        PARTITION BY tp.user_id
    ) AS total_user_plans
FROM travel_plans AS tp
JOIN travel_queries AS tq
    ON tp.travel_query_id = tq.id;