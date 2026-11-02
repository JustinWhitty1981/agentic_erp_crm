-- Not a finding. A fact, established by experiment, that migration 0004's design turns
-- on - recorded here because it was got wrong twice before it was got right, and the
-- wrong answer ("extra index columns are disregarded") is what the PostgreSQL
-- documentation appears to say if you read "index columns" as "the ones you listed".
--
-- An ON CONFLICT inference target must match a unique index's key columns EXACTLY AND IN
-- POSITIONAL ORDER. Not a subset, not a superset, not an ordered subset: the same list,
-- in the same order. Consequently an expression index can only be inferred into using
-- the identical expressions, and a tenant-scoped identity requires a tenant-scoped
-- arbiter wherever it is written.
--
-- Each experiment gets its own table, because two indexes over the same columns are not
-- two indexes for this purpose - the first one satisfies the arbiter and the second is
-- never consulted, which is itself a way to get a false pass.

BEGIN;
DO $$
DECLARE
    v    record;
    idx  text;
    arb  text;
    res  text;
    tbl  text;
    n    int := 0;
    -- Written out in full rather than constructed by substring concatenation: an
    -- attempt to build the 5-column forms from the 4-column one silently produced a
    -- doubled paren and a syntax error, which is a terrible way to discover the rule
    -- this file exists to document.
    e4  text := $i4$(item_id, warehouse_id,
              COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
              COALESCE(lot_number, ''))$i4$;
    e5t text := $i5t$(tenant_id, item_id, warehouse_id,
              COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
              COALESCE(lot_number, ''))$i5t$;
    e5l text := $i5l$(item_id, warehouse_id,
              COALESCE(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
              COALESCE(lot_number, ''), tenant_id)$i5l$;
    a4  text := e4;
    a5  text := e5l;
BEGIN
    FOR v IN
        SELECT x.t AS t, x.i AS i, x.a AS a FROM (VALUES
            ('v1_index_4_arbiter_4',            e4,  a4),
            ('v2_index_5_tenant_last_arb4',     e5l, a4),
            ('v3_index_5_tenant_first_arb4',    e5t, a4),
            ('v4_index_5_tenant_last_arb5',     e5l, a5),
            ('v5_index_5_tenant_first_arb5',    e5t, a5)
        ) AS x(t, i, a)
    LOOP
        tbl := v.t; idx := v.i; arb := v.a;
        EXECUTE format('CREATE TEMP TABLE %I (tenant_id uuid, item_id uuid, warehouse_id uuid,
                        location_id uuid, lot_number varchar) ON COMMIT DROP', tbl);
        EXECUTE format('CREATE UNIQUE INDEX ON %I %s', tbl, idx);
        BEGIN
            EXECUTE format('INSERT INTO %I (tenant_id, item_id, warehouse_id)
                            VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid())
                            ON CONFLICT %s DO NOTHING', tbl, arb);
            res := 'inferable';
        EXCEPTION WHEN invalid_table_definition THEN
            -- 42P10, the class of finding 4.2: the statement is well formed and the
            -- constraint it names does not exist to be matched.
            res := '42P10 not inferable';
        WHEN OTHERS THEN
            res := format('%s %s', SQLSTATE, left(SQLERRM, 40));
        END;
        RAISE NOTICE 'RULE %: index=% arb=% => %',
            n + 1, replace(replace(idx, E'\n', ' '), '  ', ' '),
            replace(replace(arb, E'\n', ' '), '  ', ' '), res;
        n := n + 1;
    END LOOP;
END
$$;

ROLLBACK;

-- The practical rule, in words, for whoever reads this in 0006 or 0014:
-- adding a column to a unique index is a breaking change to every ON CONFLICT written
-- against it. That is why 0004 changes the index and the function body together, and why
-- 0006 must not "improve" an index that a function infers into without checking for
-- inference sites first.
