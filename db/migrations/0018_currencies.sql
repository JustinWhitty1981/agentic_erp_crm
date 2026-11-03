-- 0018: the currency a cost is expressed in, said once and derived from there
--       (DATABASE_REVIEW.md 6.5)
--
-- 6.5 lists three things - no `currencies` table behind three `currency_code char(3)` columns,
-- no rate history anywhere, and money sharing one precision with physical quantity. Measured on
-- this server, each of those has a consequence the sentence does not say:
--
--   1. `total_cost` is written by the movement door as `p_quantity * p_unit_cost` into
--      `numeric(15,4)`. Both factors are `numeric(12,4)`, whose ceiling is just under 1e8, so the
--      product can need 1e16 while the column stops at 1e11. Measured: a receipt of 1,000,000
--      units at 1,000,000 each dies with 22003 "numeric field overflow" - a crash at the door, on
--      arithmetic the schema itself asked for. 1e5 x 1e5 = 1e10 fits, which is where the ceiling
--      actually is. This is what "money and quantity in the same precision" costs in operation.
--   2. The averaging UPDATE in the same door is
--      `(average_cost * quantity_on_hand + unit_cost * quantity) / total`, with no currency term:
--      `grep -c currency` over the installed body returns **0**. Measured through the door - a
--      balance of 100 at 10 labelled `EUR`, then a receipt of 100 at 10 - gives `average_cost =
--      10.0000` and `cost_currency = 'EUR'`, because the movement recorded USD (its column
--      default) and the balance kept whatever label it had. A dollar cost folded into a euro
--      balance, reported in euros, with nothing saying it happened.
--   3. A new balance for an item whose own `currency_code` is JPY is created as **USD** (measured):
--      `inventory_on_hand.cost_currency` has no writer in the schema at all - no function body
--      names the column - so every value in it is a column default, and the item master's
--      declared currency is contradicted by both of the tables that describe that item's money.
--   4. The de-facto currency vocabulary is every three-character string. Measured: 'XYZ' and 'xt'
--      are both accepted into `inventory_movements.currency_code`; only a fourth character is
--      refused, and that is `22001 value too long for type character(3)` - the *width* of the
--      column is the only wall, and it is a wall against typos by accident. `char`'s blank padding
--      makes it worse rather than better: the row stored as 'xt' matches `= 'xt'`, `= 'xt '` and
--      `= 'xt  '` alike, so even a careful reader cannot tell a mistyped code from its padded form.
--   5. None of this is visible to the published vocabulary register. `vw_domain_vocabulary`'s
--      candidate list is `atttypid IN ('text','varchar')` plus a name pattern, and `char(3)` is
--      neither: the three currency columns are absent from the view that `AGENTS.md` describes as
--      the answer to "what does this column accept". `verify.sh`'s B18 enumerates the same
--      candidates, so its "every domain column has an answer" census is quietly complete about a
--      set that excludes them.
--
-- What follows, in order of consequence rather than of table:
--
--   * `currencies` is master data in the shape `units_of_measure` and `costing_methods` already
--     are - global, no `tenant_id`, a natural-code primary key, `is_active` rather than deletion,
--     FK'd `ON DELETE RESTRICT` (0008's rule that a held fact is not destroyed by an edit) and a
--     single-column leading index per referencing column, because 0006's invariant does not
--     exempt low-cardinality keys and 0007's lookup FKs each got one. The ISO-4217 shape is
--     CHECKed **on the master**, once: the referencing side's mechanism is the FK, and a rule
--     stated in four places is four chances to drift. Global is a declaration and `verify.sh`'s
--     B19 is where it is made, so that file changes with this one.
--   * The currency of a cost is said in one place - the item master - and read from there by the
--     two doors that write money, through `afpc_item_currency(item_id)`. The obvious mechanism for
--     "derive this column from that one" is a column DEFAULT, and PostgreSQL forbids it: a default
--     may not reference another column of the row (measured, `cannot use column reference in
--     DEFAULT expression`, which ends the idea before the subquery ban does). A trigger could fill
--     the gap, but it cannot tell a column left at its default from a value someone meant, so it
--     would overwrite intent, which is the opinion 0007 refused to let a trigger hold. So the rule
--     is in the two bodies that write money, stated once in a function, and the watchdog for the
--     writer that forgets it is a census: §6's probe K counts balances whose stored currency
--     disagrees with their item's, and a bypassed rule shows up there as a number instead of as a
--     rumour. The census excludes this file's own probe fixtures - and asserts that the excluded set
--     is not empty, so the exclusion cannot turn into a way of not looking. A movement's own currency
--     stays stored rather than re-derived on read, because it is history: repricing an item later
--     must not change what last year's ledger row says (probe D).
--     And the census is not a formality: probe G' measures that a foreign-key check does not apply
--     row security, so a caller writing against an item it cannot see produces a row saying `USD`
--     without any constraint noticing - the one case where "the FK will catch it" is quietly false.
--   * `currency_rates` is the history 6.5 asks for, and it has a reader in the same file:
--     `vw_currency_rates` answers "is there a rate in force for this pair right now", and says
--     `in_force = false` where a pair has only expired rows, which is a different fact from
--     "no row". Rates are global - a market fact, not a tenant's - and the one-open-row promise is
--     a partial unique index rather than a trigger, because "at most one row claims to be the rate
--     now" is exactly what a `WHERE valid_to IS NULL` arbiter states. An `EXCLUDE` over a
--     timestamptz range would be the general answer and needs `btree_gist`, which 0000 did not
--     install; adding an extension to make a weaker promise is the wrong order, and §6's probe
--     notes what the weaker promise does not cover.
--   * Money gets a ceiling of its own: `numeric(18,4)` for the four unit costs and averages,
--     `numeric(24,4)` for `total_cost`, because a product of two `(12,4)` columns needs 16 integer
--     digits and `(20,4)` has only 15 (measured: 1e16 overflows `(20,4)` and fits `(24,4)`).
--     Quantities stay `(12,4)`: widening a stock column would let a balance claim 1e17 units,
--     which is not a ceiling anyone wants to test. The three views that read the widened columns
--     are captured, dropped, restored and re-armed - in that order, all of each, because PostgreSQL
--     refuses to alter the type of a column a view depends on at all (measured, 0A000), 0009's
--     reloption dies with the replace, and recreating a view one at a time restores the dependency
--     that blocks the next ALTER.
--   * `vw_inventory_valuation` gains `currency_code` in its projection *and* in its GROUP BY.
--     Under the derivation an item's balances are in the item's currency, but a warehouse holds
--     many items, and `sum(quantity_on_hand * average_cost)` across a USD item and a JPY item is
--     dollars plus yen: 0009's argument about an aggregate that does not group by `tenant_id`,
--     applied to the other axis in the same SELECT list.
--   * The register is widened, by capture-transform, so the currency columns appear in it with
--     `enforced_by = 'lookup table'` and the code table's own values, and the set of code tables is
--     derived from the catalog instead of being an array of two names - with a probe that proves
--     the derivation and the value-listing branch agree, because 0015's mapping lesson is that a
--     list is only safe when something checks its totality.
--
-- Two decisions in the other direction, both stated rather than left out:
--
--   * **Nothing converts anything.** Valuation is grouped by currency rather than translated into
--     a base one, because a translation needs three answers this schema does not have: which
--     currency is a tenant's base (no column anywhere, and `tenants` is the only plausible host),
--     which rate applies to a cost that was averaged over months of receipts (the movement dates
--     are in the ledger, the average is not), and whether an inverse is `1 / rate` or a stored
--     row. Inventing `tenants.base_currency` here would be a column with no reader - the same
--     mistake 0007 refuses for a vocabulary member no path writes - so the rates table earns its
--     keep as a record with a status view, and conversion is Obligations-0018's to decide.
--   * `warehouses.country char(2)` is measurement 4's neighbour - a code with no table, the same
--     width-as-vocabulary accident, and outside the register for the same type reason - and it is
--     not in this file. A `countries` master is a real ERP object, but 6.5 did not ask for it and
--     seeding a country list is a decision about the world, not about money. It is named here so
--     the next reader finds it in one place rather than rediscovering it.

SET client_min_messages TO notice;

-- ---------------------------------------------------------------------------
-- 1. The currency master
-- ---------------------------------------------------------------------------
-- Shape copied from `units_of_measure` (measured, and stated so the copy is deliberate): a
-- varchar-free natural key, a `label`, `is_active` instead of deletion, `created_at`. It gains
-- `updated_at` because a currency is *retired* - an `is_active` flip is the event a deployment
-- would want dated, and 0010's touch function is one line to install, so the alternative is a
-- code table whose only mutable fact carries no timestamp.
CREATE TABLE currencies (
    currency_code char(3)     PRIMARY KEY,
    label         text         NOT NULL,
    minor_units   smallint     NOT NULL,
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT currencies_code_shape CHECK (currency_code ~ '^[A-Z]{3}$'),
    -- The ceiling on minor_units is not ISO 4217's (which reaches 2 for most, 0 for JPY, and has
    -- outliers in circulation): it is this schema's money scale, stated as a constraint so the
    -- two cannot drift apart. A 5-minor-unit currency would need the money columns widened first,
    -- and probe H reads the scale off the catalog rather than from this line.
    CONSTRAINT currencies_minor_units_range CHECK (minor_units BETWEEN 0 AND 4)
);

COMMENT ON TABLE currencies IS
    'ISO 4217 currency codes: the master data behind the three currency columns the baseline put '
    'in the inventory model with no table to point at (6.5). Global by decision - a currency is a '
    'fact about money, not about a tenant - which is declared in verify.sh''s B19 rather than left '
    'as an absence, the same exemption units_of_measure and costing_methods carry. Retired with '
    'is_active, never deleted: the FKs are RESTRICT (0008), and a balance priced in a currency that '
    'has ceased to exist is a history question, not a cleanup. currency_code''s shape is CHECKed '
    'here and nowhere else: the referencing columns'' mechanism is the foreign key, and a rule '
    'stated on both sides of a relationship is two rules. Built by 0018.';
COMMENT ON COLUMN currencies.minor_units IS
    'Decimal digits in circulation (USD 2, JPY 0). Kept because it bounds the money columns: no '
    'currency here may need more digits than their scale provides, and probe H asserts that from '
    'pg_attribute rather than from this comment. It is not used to round anything - nothing '
    'converts yet.';

-- The seed has to include every value the live columns can already produce, or the FK turns the
-- default into an INSERT failure: all three columns are NOT NULL DEFAULT 'USD'::bpchar (measured),
-- so USD is not a preference of this file, it is a precondition. The rest are the currencies the
-- probes and a plausible first deployment name, and the list grows with an INSERT - which is the
-- whole reason it is a table and not a CHECK list (0007's rule, repeated here because 6.5 is the
-- first time the schema is asked for a third code table).
INSERT INTO currencies (currency_code, label, minor_units) VALUES
    ('USD', 'US dollar',        2),
    ('EUR', 'Euro',             2),
    ('JPY', 'Japanese yen',     0),
    ('GBP', 'Pound sterling',   2),
    ('CHF', 'Swiss franc',      2),
    ('CAD', 'Canadian dollar',  2),
    ('AUD', 'Australian dollar',2),
    ('CNY', 'Chinese yuan',     2),
    ('INR', 'Indian rupee',     2)
    ON CONFLICT (currency_code) DO NOTHING;

-- The three edges 6.5 says are missing, plus 0006's invariant for each. RESTRICT in all three:
-- an item priced in a retired currency, a movement that happened in one, and a balance averaged in
-- one are all facts a later edit must not be able to erase by deleting a row from master data.
ALTER TABLE inventory_items
    ADD CONSTRAINT inventory_items_currency_code_fkey
    FOREIGN KEY (currency_code) REFERENCES currencies(currency_code) ON DELETE RESTRICT;
ALTER TABLE inventory_movements
    ADD CONSTRAINT inventory_movements_currency_code_fkey
    FOREIGN KEY (currency_code) REFERENCES currencies(currency_code) ON DELETE RESTRICT;
ALTER TABLE inventory_on_hand
    ADD CONSTRAINT inventory_on_hand_cost_currency_fkey
    FOREIGN KEY (cost_currency) REFERENCES currencies(currency_code) ON DELETE RESTRICT;

CREATE INDEX idx_items_currency_code      ON inventory_items      (currency_code);
CREATE INDEX idx_movements_currency_code  ON inventory_movements  (currency_code);
CREATE INDEX idx_on_hand_cost_currency    ON inventory_on_hand    (cost_currency);

COMMENT ON CONSTRAINT inventory_items_currency_code_fkey ON inventory_items IS
    '6.5''s missing edge, and after §3 the source of the other two: an item''s currency is the '
    'currency its costs are in, and the movement ledger and the balance derive from it. The column '
    'keeps its char(3) type - membership is now the constraint, so char''s blank-padding '
    'semantics stop mattering, and a type change would rewrite three tables and force the view '
    'dance of §4 for no added promise.';

-- ---------------------------------------------------------------------------
-- 2. The rate history, and a view that says whether a pair has a rate at all
-- ---------------------------------------------------------------------------
-- The key decision here is what the table promises *mechanically* versus in prose, because rates
-- are the one part of 6.5 that a deployment fills in from outside. One open row per ordered pair
-- is a partial unique index - "at most one row claims to be the rate now" is exactly what
-- `WHERE valid_to IS NULL` states, and a trigger that enforced it would be 0007's rejected
-- "trigger with opinions". The general bitemporal promise - no overlaps *and* no gaps anywhere in
-- a pair's history - needs `EXCLUDE USING gist` over a timestamptz range, which needs btree_gist,
-- which 0000 did not install: adding an extension to make a weaker guarantee than this index
-- already makes is the wrong order, so gaps are stated as unguarded (probe E shows one existing
-- quietly) and whoever builds conversion decides whether they may.
--
-- `valid_from` has no DEFAULT on purpose. A rate is inserted because it *was* quoted on a date,
-- usually after the fact; defaulting it to now() would turn a forgotten argument into a claim that
-- the rate began at this instant. `rate > 0` is the whole sign convention: an inverse is computed
-- as a reciprocal, never as a negative, and a zero rate would mean stock acquired for nothing.
-- The pair cannot be an identity because identity is 1 by definition - storing USD->USD is a row
-- that can disagree with the arithmetic, which is 0015's mapping lesson applied to a table.
CREATE TABLE currency_rates (
    rate_id       uuid          PRIMARY KEY DEFAULT afpc_uuid_v7(),
    from_currency char(3)       NOT NULL,
    to_currency   char(3)       NOT NULL,
    rate          numeric(18,8) NOT NULL,
    valid_from    timestamptz   NOT NULL,
    valid_to      timestamptz,
    source        text,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT currency_rates_from_fkey
        FOREIGN KEY (from_currency) REFERENCES currencies(currency_code) ON DELETE RESTRICT,
    CONSTRAINT currency_rates_to_fkey
        FOREIGN KEY (to_currency)   REFERENCES currencies(currency_code) ON DELETE RESTRICT,
    CONSTRAINT currency_rates_not_identity CHECK (from_currency <> to_currency),
    CONSTRAINT currency_rates_positive     CHECK (rate > 0),
    CONSTRAINT currency_rates_valid_window CHECK (valid_to IS NULL OR valid_to > valid_from)
);

-- (from, to, valid_from) serves the lookup a converter will do and satisfies 0006's invariant for
-- from_currency; the reverse index does the same for to_currency, because "which rates feed EUR"
-- is asked from the other side of the same pair. The partial unique is the promise; it also leads
-- with from_currency, so the invariant holds twice over rather than by luck.
CREATE INDEX idx_rates_pair_from ON currency_rates (from_currency, to_currency, valid_from DESC);
CREATE INDEX idx_rates_to        ON currency_rates (to_currency, valid_from DESC);
CREATE UNIQUE INDEX uq_rates_one_current
    ON currency_rates (from_currency, to_currency) WHERE valid_to IS NULL;

COMMENT ON TABLE currency_rates IS
    'One row per currency pair per period: the rate history 6.5 found missing, so that a cost '
    'valuation no longer has to assume one rate forever. It does not yet change any valuation - '
    'nothing converts (§0''s first declined decision): who the base currency of a tenant is, which '
    'rate applies to an average built from months of receipts, and whether an inverse is a '
    'reciprocal or a stored row are three decisions this file refuses to make as a side effect of '
    'a CREATE TABLE. Global by decision like the other master data, so verify.sh''s B19 declares '
    'it, and outside 0013''s trail because audit_log.tenant_id is NOT NULL and no tenant owns a '
    'market rate - probe L asserts that boundary rather than leaving it to be noticed. The '
    'mechanical promise is one open row per pair; overlaps across closed rows and gaps between '
    'them are not constrained, and probe E demonstrates the gap rather than claiming it away.';
COMMENT ON COLUMN currency_rates.source IS
    'Where the number came from: a feed name, a bank, a manual entry. Free text by the same '
    'reasoning 0007 applied to bot_actions.action_type - it names an integration endpoint, which '
    'changes with deployments rather than with releases, and constraining it would make every new '
    'feed a migration. Its absence is also information: a rate nobody can attribute.';

-- The reader this table needs to be more than a filing cabinet: one row per pair that has ever had
-- a rate, showing the one in force at the start of the statement, and distinguishing "expired"
-- from "never existed" - the difference between an absent fact and a null join pretending nobody
-- asked. Pairs with no rows are absent from here and the comment says so, because the alternative
-- is a cross join over the currency master growing quadratically inside a view someone scans.
CREATE OR REPLACE VIEW vw_currency_rates AS
SELECT p.from_currency,
       p.to_currency,
       f.rate          AS rate_in_force,
       f.valid_from,
       f.valid_to,
       f.source,
       (f.rate_id IS NOT NULL) AS in_force,
       (SELECT count(*) FROM currency_rates h
         WHERE h.from_currency = p.from_currency AND h.to_currency = p.to_currency)
                               AS rows_for_pair,
       now()                   AS as_of
  FROM (SELECT DISTINCT currency_rates.from_currency, currency_rates.to_currency
          FROM currency_rates) p
  LEFT JOIN LATERAL (
        SELECT r.rate, r.valid_from, r.valid_to, r.rate_id, r.source
          FROM currency_rates r
         WHERE r.from_currency = p.from_currency
           AND r.to_currency   = p.to_currency
           AND r.valid_from <= now()
           AND (r.valid_to IS NULL OR r.valid_to > now())
         ORDER BY r.valid_from DESC
         LIMIT 1
       ) f ON true;

COMMENT ON VIEW vw_currency_rates IS
    'For every pair the schema has ever held a rate for: the row in force as of the statement '
    '(as_of makes that explicit - a view that quietly contained now() would answer a different '
    'question on every scan), in_force false where the pair''s rows have all expired, and '
    'rows_for_pair so an empty history and an expired one read differently. A pair never quoted '
    'appears in no row at all. Built by 0018, global by decision, and deliberately not joined '
    'into vw_inventory_valuation: that would be conversion by another name, with the rate '
    'silently chosen by a LEFT JOIN''s NULL handling.';

-- Both tables are mutable master data with an updated_at, which is 0010's scope statement exactly:
-- "a table that has the column has the trigger", read from the catalog rather than remembered. The
-- two lines are here rather than in §1 because the second table is created below it, and 0010's
-- census is the one that counts them - this file moves its "tables whose updated_at is maintained"
-- row from 15 to 17 and its trigger count from 36 to 38.
CREATE TRIGGER afpc_touch_updated_at
    BEFORE INSERT OR UPDATE ON public.currencies
    FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();
CREATE TRIGGER afpc_touch_updated_at
    BEFORE INSERT OR UPDATE ON public.currency_rates
    FOR EACH ROW EXECUTE FUNCTION afpc_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Where a cost's currency comes from
-- ---------------------------------------------------------------------------
-- Measurement 3 is the one that decides this section: no function body in the schema names
-- `cost_currency` or `currency_code` at all (counted over pg_get_functiondef for every domain
-- function: 0), so both columns have held their own default, 'USD', since 0001 while the item
-- master was free to say otherwise. This section states the rule once, as a function; §3b puts it
-- into the two bodies that write money.
--
-- The three mechanisms that could have carried it, and why each was not taken.
--
--   * A column DEFAULT calling this function with the row's own key is the obvious one, and
--     PostgreSQL forbids it outright: `cannot use column reference in DEFAULT expression`. The
--     shape that suggests itself next - wrap the read in a subquery so the default is not naming a
--     column - is forbidden separately, `cannot use subquery in DEFAULT expression`. Two walls, so
--     the mechanism is not nearly available.
--   * A generated column is closer than it looks, and that is the reason to write it down. Its
--     expression may name another column of the same row - the shape PostgreSQL does allow - but it
--     has to be immutable, and `42P17 generation expression is not immutable` is what this STABLE
--     function answers. The way round is to declare the reader IMMUTABLE, and measured, that
--     `works`: the column is created, and its value then goes stale on every edit to the table it
--     read, with nothing left to notice. A mechanism whose failure mode is silence is the one
--     mechanism this schema must not use for money.
--   * A trigger was refused for the reason 0007 gave about vocabulary columns: a BEFORE INSERT
--     trigger cannot tell a column the caller left alone from a column the caller meant, so it
--     overwrites intent. Here there is no intent to overwrite, which is what makes a trigger
--     tempting, and it is still the wrong place: the derivation belongs with the arithmetic that
--     uses it, and §3b needs a second statement of the rule anyway for the case the helper cannot
--     see. Two mechanisms holding one rule is 3.3 in miniature.
--
-- So it is a function, called by the doors, and the thing that keeps it honest is a census
-- (§6's probe K) rather than a guarantee.
CREATE OR REPLACE FUNCTION afpc_item_currency(p_item_id uuid)
 RETURNS char(3)
 LANGUAGE sql STABLE
AS $$
    SELECT i.currency_code FROM inventory_items i WHERE i.item_id = p_item_id;
$$;

COMMENT ON FUNCTION afpc_item_currency(uuid) IS
    'The currency an item''s costs are expressed in - the item master read once, so that the '
    'movement ledger and the on-hand balance cannot each invent their own answer (6.5''s third '
    'measurement: both columns held the column default ''USD'' because no function body named '
    'them). STABLE and SECURITY INVOKER, deliberately: the read goes through row security, so a '
    'caller cannot derive a fact about another tenant''s item, and a DEFINER version would be a '
    'window 0009 closed everywhere else. Returns NULL for an item that does not exist or that the '
    'caller''s row security cannot see, which is how probe G''s second half distinguishes an '
    'invisible item from an absent one. Called by the two doors that write money (§3b) and by '
    'nothing else - a fact this file''s probe N counts. Built by 0018; a mechanism, not a door, so '
    'it is revoked from PUBLIC like the others.';

REVOKE EXECUTE ON FUNCTION afpc_item_currency(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION afpc_item_currency(uuid) TO afpc_app;


COMMENT ON COLUMN inventory_movements.currency_code IS
    'Which currency unit_cost and total_cost are denominated in. The two doors that write money '
    'name the column and take its value from the item master (§3); every other write path leaves '
    'the column default, which is why §0 prefers a census over a claim here. Stored rather than '
    'derived on read, because a ledger row must keep the currency its own cost was in: repricing '
    'history when an item''s currency changes later is measurement 3 inverted, not fixed (probe D).';
COMMENT ON COLUMN inventory_on_hand.cost_currency IS
    'The currency average_cost is expressed in. An item is priced in exactly one currency and the '
    'balance''s unique key does not include currency, so one balance row cannot hold two: the '
    'created-by-a-door path takes this from the item master (§3b), and §3b refuses a movement whose '
    'currency has drifted away from the balance it would average into. Rows that already disagree '
    '- which is every row before 0018, because the column default said USD while the item master '
    'was free to say anything - are counted by probe K, not repaired here. Rewriting an average to '
    'a different currency without converting it is measurement 2 with better manners.';
COMMENT ON COLUMN inventory_items.currency_code IS
    'The source of truth for the other two currency columns after 0018: the currency this item''s '
    'standard_cost, last_cost and every movement of it are in. Kept its char(3) type and its '
    '''USD'' default - dropping the default would make an unnamed item refuse to insert, and the '
    'item master has no creation door to be strict at (there is no add_item: a new item arrives by '
    'raw INSERT). Changing it is therefore a raw-UPDATE-only hazard, and §3b is what makes it '
    'loud: the next movement against a balance left behind refuses instead of blending.';

-- ---------------------------------------------------------------------------
-- 3b. The one contradiction the derivation cannot prevent, refused at the door
-- ---------------------------------------------------------------------------
-- §3 says where the answer lives; this section puts it in the two bodies that write money, and
-- adds the one refusal the derivation cannot express. Reading the item master is enough for a row that
-- does not exist yet; that leaves
-- exactly one way to reach measurement 2: a balance already exists in one currency and the item
-- master has since moved to another, and the averaging statement that would then run converts
-- nothing. The derivation cannot see that case, because it answers "what currency is this item
-- priced in", not "what currency is this balance kept in". So the guard reads both.
--
-- It stands where 0015 put the shortage decision - before the ledger row, so a refusal leaves
-- nothing behind. The body is changed by capture-transform (ask the catalog
-- for the text, apply two single-line needles, refuse to run if either appears other than exactly
-- once, re-execute), because 0015's body is a couple of hundred lines of reasoning this section has
-- no business retyping and a rewrite from memory is how a fix loses someone else's guard.
--
-- Why not a trigger: the schema's one cross-column invariant (`update_on_hand_consistency`)
-- *rewrites* a value, and 0007 refused exactly that for vocabulary columns. A check that spans
-- tables cannot be a CHECK, and ON UPDATE RESTRICT guards the referenced key in `currencies`, not a
-- referencing column moving. Four lines in the one door that computes an average is the mechanism
-- this schema has.
DO $$
DECLARE
    v_body  text;
    v_new   text;
    v_hits  int;
    t       record;
BEGIN
    ------------------------------------------------------------------
    -- execute_inventory_movement. Six needles, each single-line, each counted: the DECLARE slot,
    -- the guard, and the four INSERT lists and value lists that gain the column §0's measurement 3
    -- says nothing ever wrote. Two needles match twice, because the door has two branches that
    -- create a balance, and a needle allowed to match twice must match everywhere or nowhere - a
    -- partial patch leaves one branch writing the old way, which is the two-copies failure this
    -- whole section exists to avoid.
    ------------------------------------------------------------------
    SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'execute_inventory_movement';
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement'
          AND prokind = 'f') <> 1 THEN
        RAISE EXCEPTION '§3b found % heads of execute_inventory_movement and will not '
                        'capture-transform an ambiguous name - that is 4.4 wearing a transform',
            (SELECT count(*) FROM pg_proc WHERE proname = 'execute_inventory_movement');
    END IF;
    IF v_body IS NULL THEN
        RAISE EXCEPTION '§3b found no execute_inventory_movement to transform';
    END IF;

    FOR t IN SELECT * FROM (VALUES
        (E'    v_state       text      := '''';',
         E'    v_state       text      := '''';\n    v_currency    char(3);',
         1, 'the DECLARE slot both the derivation and the refusal use'),
        (E'    INSERT INTO inventory_movements (',
         E'    ------------------------------------------------------------------\n'
       || E'    -- 0018: the currency this movement''s cost is in is the item''s, and every balance\n'
       || E'    -- this call touches has to agree, because the averaging below converts nothing.\n'
       || E'    -- Decided before the ledger row, where 0015 decided the shortage.\n'
       || E'    ------------------------------------------------------------------\n'
       || E'    v_currency := afpc_item_currency(p_item_id);\n'
       || E'    SELECT count(*) INTO v_rows_here FROM inventory_on_hand h\n'
       || E'     WHERE h.item_id = p_item_id\n'
       || E'       AND h.warehouse_id IN (p_from_warehouse_id, p_to_warehouse_id)\n'
       || E'       AND h.cost_currency IS DISTINCT FROM v_currency;\n'
       || E'    IF v_rows_here > 0 THEN\n'
       || E'        RAISE EXCEPTION ''execute_inventory_movement: % balance row(s) for item % keep a ''\n'
       || E'                        ''currency other than the item''''s % - average_cost cannot blend ''\n'
       || E'                        ''two'',\n'
       || E'            v_rows_here, p_item_id, v_currency\n'
       || E'            USING ERRCODE = ''23514'',\n'
       || E'                  HINT = ''the item master moved after the balance was created, or the ''\n'
       || E'                        ''balance predates 0018; currency_rates holds rates and nothing ''\n'
       || E'                        ''converts with them yet'';\n'
       || E'    END IF;\n'
       || E'\n'
       || E'    INSERT INTO inventory_movements (',
         1, 'the guard, at the point where nothing has been written yet'),
        (E'        quantity, unit_cost, total_cost, unit_of_measure, performed_by,',
         E'        quantity, unit_cost, total_cost, unit_of_measure, performed_by, currency_code,',
         1, 'the ledger row''s column list'),
        (E'        p_quantity, p_unit_cost, p_quantity * p_unit_cost, v_uom, p_performed_by,',
         E'        p_quantity, p_unit_cost, p_quantity * p_unit_cost, v_uom, p_performed_by, v_currency,',
         1, 'the ledger row''s values'),
        (E'            (item_id, warehouse_id, location_id, quantity_on_hand, average_cost, last_movement_at)',
         E'            (item_id, warehouse_id, location_id, quantity_on_hand, average_cost, cost_currency, last_movement_at)',
         2, 'a new balance''s column list, in both branches that create one'),
        (E'        VALUES (p_item_id, p_to_warehouse_id, p_to_location_id, p_quantity, p_unit_cost, NOW())',
         E'        VALUES (p_item_id, p_to_warehouse_id, p_to_location_id, p_quantity, p_unit_cost, v_currency, NOW())',
         2, 'a new balance''s values, in both branches that create one')
    ) AS n(needle, patch, times, which)
    LOOP
        v_hits := array_length(string_to_array(v_body, t.needle), 1) - 1;
        IF v_hits <> t.times THEN
            RAISE EXCEPTION '§3b''s % needle matched % times in execute_inventory_movement, '
                            'expected % - the body this transform was written against is not the '
                            'one 0015 §3 left, and patching it anyway would move a branch this '
                            'migration has not read', t.which, v_hits, t.times;
        END IF;
        v_new := replace(v_body, t.needle, t.patch);
        IF v_new = v_body THEN
            RAISE EXCEPTION '§3b''s % patch did not apply', t.which;
        END IF;
        v_body := v_new;
    END LOOP;
    EXECUTE v_body;
    RAISE NOTICE '6.5 §3b: the movement door derives the currency it writes, and refuses where a '
                 'balance has drifted away from it';

    ------------------------------------------------------------------
    -- reserve_inventory_for_order: the commitment row 0015 chose to keep. It carries no cost, so
    -- nothing averages and nothing blends and the guard does not belong here - but a ledger row
    -- that says USD beside an item priced in yen is still a row that says something false, and the
    -- reservation door deducts quantity_available from a balance whose own currency it never reads.
    ------------------------------------------------------------------
    SELECT pg_get_functiondef(p.oid) INTO v_body
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'reserve_inventory_for_order';
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'reserve_inventory_for_order') <> 1 THEN
        RAISE EXCEPTION '§3b found % heads of reserve_inventory_for_order',
            (SELECT count(*) FROM pg_proc WHERE proname = 'reserve_inventory_for_order');
    END IF;
    FOR t IN SELECT * FROM (VALUES
        (E'             unit_of_measure, reason_code, performed_by, reference_type, reference_id)',
         E'             unit_of_measure, reason_code, performed_by, reference_type, reference_id, currency_code)',
         'the commitment row''s column list'),
        (E'             ''ORDER_COMMITMENT'', p_reserved_by,',
         E'             ''ORDER_COMMITMENT'', p_reserved_by, afpc_item_currency(p_item_id),',
         'the commitment row''s values')
    ) AS n(needle, patch, which)
    LOOP
        v_hits := array_length(string_to_array(v_body, t.needle), 1) - 1;
        IF v_hits <> 1 THEN
            RAISE EXCEPTION '§3b''s % needle matched % times in reserve_inventory_for_order - the '
                            'row 0015 §4 kept is not where this transform was written to find it',
                t.which, v_hits;
        END IF;
        v_new := replace(v_body, t.needle, t.patch);
        IF v_new = v_body THEN
            RAISE EXCEPTION '§3b''s % patch did not apply', t.which;
        END IF;
        v_body := v_new;
    END LOOP;
    EXECUTE v_body;
    RAISE NOTICE '6.5 §3b: the reservation door''s ledger row names the currency too';

    -- The calls have to be in both bodies, not merely in the text this block assembled.
    IF (SELECT (array_length(string_to_array(prosrc, 'afpc_item_currency(p_item_id)'), 1) - 1)
          FROM pg_proc WHERE proname = 'reserve_inventory_for_order') <> 1
       OR (SELECT (array_length(string_to_array(prosrc, 'v_currency'), 1) - 1) FROM pg_proc
            WHERE proname = 'execute_inventory_movement') < 4 THEN
        RAISE EXCEPTION '§3b ran and the derivation is not in the installed bodies - the transform '
                        'patched a text that was then discarded';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Money gets a ceiling of its own
-- ---------------------------------------------------------------------------
-- Measurement 1 is the finding in its concrete form: the door writes quantity * unit_cost into
-- total_cost, both factors are (12,4) - ceiling just under 1e8 - and the product therefore needs
-- 16 integer digits while the column stops at 11. Widening the *factors* would not help: two
-- 1e8-scale numbers still multiply to 1e16. So the ceiling has to be sized from the arithmetic,
-- not from the columns: 1e16 fits (24,4) and does not fit (20,4) (measured), which is the whole
-- reason for the odd-looking number.
--
-- Unit costs and averages go to (18,4): a ceiling of 1e14 per unit is not something a stock cost
-- approaches, and the scale stays 4 so §1's minor_units constraint keeps meaning "at least as many
-- digits as any currency here needs". Quantities stay (12,4) on purpose: raising a stock ceiling
-- would let a balance assert 1e17 units, and the finding is that money and quantity share a
-- precision, not that either was too small.
--
-- The widening cannot be done in place while views read those columns - PostgreSQL refuses with
-- 0A000 (measured on both average_cost and unit_cost) - so this is the capture/drop/alter/recreate
-- dance, with the two facts that dance always threatens proved: nothing downstream depended on the
-- three views, and every one comes back with the columns and the comment it had, the reloption
-- 0009 says dies with a replace, and the grants. vw_inventory_valuation is the deliberate
-- exception to "the same columns": it gains currency_code, because an item's balances are now in
-- the item's currency but a warehouse holds many items, and sum(quantity * cost) across a USD
-- item and a JPY item is dollars plus yen - 0009's complaint about an aggregate that omits a
-- grouping key, on the other axis in the same SELECT list.
DO $$
DECLARE
    v_new       text;
    v_hits      int;
    v_dependent text;
    r           record;
BEGIN
    -- Nothing may depend on the three views, because a DROP takes their dependents with it and
    -- CASCADE is not available here. Checked rather than assumed: 0009 built views over these same
    -- bases, and a later migration that added one over them would turn this section into an
    -- accident. A view's own rewrite depends on it, which is not a dependent.
    SELECT string_agg(DISTINCT dv.relname, ', ' ORDER BY dv.relname) INTO v_dependent
      FROM pg_depend d
      JOIN pg_rewrite rw ON rw.oid = d.objid
      JOIN pg_class dv ON dv.oid = rw.ev_class AND dv.relkind = 'v'
      JOIN pg_class bv ON bv.oid = d.refobjid
     WHERE d.classid = 'pg_rewrite'::regclass
       AND bv.oid IN ('vw_inventory_valuation'::regclass, 'vw_item_availability'::regclass,
                      'vw_item_movement_summary'::regclass)
       AND dv.oid <> bv.oid;
    IF v_dependent IS NOT NULL THEN
        RAISE EXCEPTION 'a view depends on % - §4 would drop the base view with it, so the '
                        'dependent has to be captured and restored in this same section and is not',
            v_dependent;
    END IF;

    -- Capture first, drop second, alter third, recreate last. The order is not fussiness: a
    -- recreated view restores the dependency the ALTER is refused by, so a loop that drops and
    -- recreates one view at a time gets exactly one ALTER in before the wall comes back (the first
    -- rehearsal of this section proved it by failing on the second).
    CREATE TEMP TABLE afpc_0018_view_capture ON COMMIT DROP AS
        SELECT v::text AS viewname,
               pg_get_viewdef(format('public.%s', v)::regclass, true) AS body,
               (SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute a
                 WHERE a.attrelid = format('public.%s', v)::regclass
                   AND a.attnum > 0 AND NOT a.attisdropped) AS cols,
               obj_description(format('public.%s', v)::regclass, 'pg_class') AS viewcomment
          FROM unnest(ARRAY['vw_inventory_valuation','vw_item_availability',
                            'vw_item_movement_summary']) AS v;

    IF (SELECT count(*) FROM afpc_0018_view_capture WHERE body IS NULL
          OR cols IS NULL OR viewname IS NULL) <> 0 THEN
        RAISE EXCEPTION 'a view this section must restore printed no definition or no column '
                        'list - the recreation would be authored from memory';
    END IF;

    -- The one intended change of meaning, applied to the captured text: two single-line needles
    -- (0015's lesson, that an exact multi-line literal fails on a formatting change rather than a
    -- meaning change), each counted as a literal substring rather than through regexp_matches,
    -- whose parentheses would make the guard contradict the operation it guards.
    v_hits := array_length(string_to_array(
        (SELECT body FROM afpc_0018_view_capture WHERE viewname = 'vw_inventory_valuation'),
        'sum(ioh.quantity_available * ioh.average_cost) AS available_value,'), 1) - 1;
    IF v_hits <> 1 THEN
        RAISE EXCEPTION 'the projection needle matched % times in vw_inventory_valuation', v_hits;
    END IF;
    UPDATE afpc_0018_view_capture
       SET body = replace(body,
           'sum(ioh.quantity_available * ioh.average_cost) AS available_value,',
           E'sum(ioh.quantity_available * ioh.average_cost) AS available_value,\n'
         || E'     ioh.cost_currency AS currency_code,')
     WHERE viewname = 'vw_inventory_valuation';
    v_hits := array_length(string_to_array(
        (SELECT body FROM afpc_0018_view_capture WHERE viewname = 'vw_inventory_valuation'),
        'cat.name, ioh.tenant_id;'), 1) - 1;
    IF v_hits <> 1 THEN
        RAISE EXCEPTION 'the GROUP BY needle matched % times in vw_inventory_valuation - the '
                        'currency would be grouped by something other than the one clause meant '
                        'to change', v_hits;
    END IF;
    UPDATE afpc_0018_view_capture
       SET body = replace(body, 'cat.name, ioh.tenant_id;',
                               'cat.name, ioh.tenant_id, ioh.cost_currency;')
     WHERE viewname = 'vw_inventory_valuation';

    FOR r IN SELECT viewname FROM afpc_0018_view_capture ORDER BY viewname LOOP
        EXECUTE 'DROP VIEW public.' || quote_ident(r.viewname);
    END LOOP;

    ALTER TABLE inventory_items     ALTER COLUMN standard_cost TYPE numeric(18,4);
    ALTER TABLE inventory_items     ALTER COLUMN last_cost     TYPE numeric(18,4);
    ALTER TABLE inventory_movements ALTER COLUMN unit_cost     TYPE numeric(18,4);
    ALTER TABLE inventory_on_hand   ALTER COLUMN average_cost  TYPE numeric(18,4);
    ALTER TABLE inventory_movements ALTER COLUMN total_cost    TYPE numeric(24,4);

    -- The other half of 6.5's last sentence: conversion_factor "exists but is unvalidated". A
    -- factor of 0 zeroes a converted quantity and a negative one flips a direction, and both pass
    -- through the arithmetic silently - the same shape as 0014's sign checks on the ledger.
    ALTER TABLE inventory_movements
        ADD CONSTRAINT inventory_movements_conversion_positive
        CHECK (conversion_factor IS NULL OR conversion_factor > 0);

    FOR r IN SELECT * FROM afpc_0018_view_capture ORDER BY viewname LOOP
        EXECUTE 'CREATE VIEW public.' || quote_ident(r.viewname) || ' AS ' || r.body;
        EXECUTE format('COMMENT ON VIEW public.%I IS %L', r.viewname, r.viewcomment);
        -- 0009's ordering, which a DROP/CREATE makes easy to forget: the option belongs to the
        -- object, so a fresh view is born running as its owner and B21 counts it.
        EXECUTE 'ALTER VIEW public.' || quote_ident(r.viewname)
             || ' SET (security_invoker = true)';
        EXECUTE 'GRANT SELECT ON public.' || quote_ident(r.viewname)
             || ' TO afpc_readonly, afpc_auditor';

        SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_new
          FROM pg_attribute WHERE attrelid = format('public.%s', r.viewname)::regclass
            AND attnum > 0 AND NOT attisdropped;
        IF r.viewname = 'vw_inventory_valuation' THEN
            IF v_new IS DISTINCT FROM
               replace(r.cols, ',tenant_id', ',currency_code,tenant_id') THEN
                RAISE EXCEPTION 'vw_inventory_valuation came back as (%) instead of its old '
                                'columns with currency_code added before tenant_id (%)',
                    v_new, replace(r.cols, ',tenant_id', ',currency_code,tenant_id');
            END IF;
        ELSIF v_new IS DISTINCT FROM r.cols THEN
            RAISE EXCEPTION '% came back with a different column list (% -> %) - the type '
                            'widening was meant to be invisible to readers',
                r.viewname, r.cols, v_new;
        END IF;
        RAISE NOTICE '6.5: % restored (% columns)', r.viewname,
            (SELECT count(*) FROM unnest(string_to_array(v_new, ',')));
    END LOOP;

    -- The comment the DROP took with it, on the one view whose prose has to change: it now answers
    -- a question per currency, which is what the added column is for.
    COMMENT ON VIEW vw_inventory_valuation IS
        'Inventory value by warehouse and category, per currency: an item''s balances are in the '
        'item''s currency (§3b), but a warehouse holds many items, and sum(quantity * cost) across '
        'a USD item and a JPY item is dollars plus yen. currency_code is in the projection and in '
        'the GROUP BY for the reason 0009 gave about tenant_id - an aggregate that leaves a '
        'dimension out adds two of them together and reports one number. Nothing converts: '
        'currency_rates holds rates and no view reads them, so the honest answer is one row per '
        'currency, and the sum across currencies is whoever builds conversion''s to decide. '
        'Rewritten by 0018, which also widened the money columns this sums.';
END
$$;

-- Which columns are money, said where a reader can find it. The distinction is not encoded in a
-- type this schema can express (a domain would be machine-readable but hides the base type from
-- the information_schema queries verify.sh's census is built on - the inert-check failure mode
-- again), so it is encoded in the ceiling, in these comments, and in probe I, which reads the two
-- groups apart and fails the day they converge.
COMMENT ON COLUMN inventory_items.standard_cost IS
    'Money, not a quantity: numeric(18,4) since 0018, in the currency of §3''s derivation. The '
    'four money columns are the unit costs and averages - this, last_cost, unit_cost, average_cost.';
COMMENT ON COLUMN inventory_movements.total_cost IS
    'quantity * unit_cost, so its ceiling is set by the product of two 12-digit columns (1e16) and '
    'not by either of them: numeric(24,4) after 0018, which is the column measurement 1 killed.';
COMMENT ON COLUMN inventory_movements.conversion_factor IS
    'Units moved per base unit, CHECKed positive by 0018. Still unvalidated against the item''s '
    'base_unit_of_measure - a factor only means something relative to a named unit, and that '
    'relationship is the multi-UOM decision 6.5 points at, which needs a unit-of-measure dimension '
    'on the factor to be checkable at all. Named in Obligations-0018 rather than half-done here.';

-- ---------------------------------------------------------------------------
-- 5. The vocabulary register, widened so it can see what it now constrains
-- ---------------------------------------------------------------------------
-- Measurement 5. `vw_domain_vocabulary` is what AGENTS.md calls "what every status/type column
-- accepts", and its candidate filter is `atttypid IN ('text','varchar')` plus a name pattern:
-- `char(3)` is neither of those types and `currency_code` matches none of those shapes, so the
-- three columns this file has just given real constraints were going to stay invisible to the
-- published answer about them - and `verify.sh`'s B18 builds its candidate list from the same two
-- conditions, so the census that says "0 domain columns have no published answer" was quietly
-- complete about a set that excluded them. Both halves move together, because a register and a
-- check that disagree about the candidate set is one check that passes for two reasons.
--
-- Widening the type list is also what found the exemption this section needed. The first rehearsal
-- of the new register put `currencies.currency_code` in it as UNDECIDED - a master table's own key
-- had started to look like a vocabulary column, because the name shape is exactly what a currency
-- column is named by. The answer is not a CHECK on the master's key (that would be §1's rule stated
-- twice) but a statement that a code table is a value space rather than a use of one, and the
-- exemption is derived from the catalog by the same predicate as the set of code tables, for the
-- same reason B19 declares global tables instead of leaving their absence to be noticed.
--
-- The `lk` arm also stops being a list of two table names. `vw_rls_status`'s B19 comment says a new
-- global table has to be considered rather than skipped; the same argument applies one level down,
-- and the derivation is short: in `public`, not the two infrastructure tables, no `tenant_id`,
-- single-column text-ish primary key. That is `units_of_measure`, `costing_methods` and now
-- `currencies`, and nothing else - probe J asks the catalog the same question from the other side
-- and fails if the register's value-listing arm has fallen behind, because a derived set and a
-- hand-written UNION are two rules the moment nobody checks they agree.
DO $$
DECLARE
    v_body     text;
    v_new      text;
    v_hits     int;
    v_before   text;
    v_after    text;
    v_comment  text;
    t          record;
    v_derived  text;
BEGIN
    SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_before
      FROM pg_attribute WHERE attrelid = 'vw_domain_vocabulary'::regclass
        AND attnum > 0 AND NOT attisdropped;
    SELECT obj_description('public.vw_domain_vocabulary'::regclass, 'pg_class') INTO v_comment;
    SELECT pg_get_viewdef('public.vw_domain_vocabulary'::regclass, true) INTO v_body;
    IF v_body IS NULL THEN
        RAISE EXCEPTION 'vw_domain_vocabulary printed no definition to transform';
    END IF;

    v_derived := $der$ (SELECT cc.oid FROM pg_class cc
                          JOIN pg_namespace nn ON nn.oid = cc.relnamespace
                           AND nn.nspname = 'public'
                         WHERE cc.relkind = 'r'
                           AND cc.relname NOT IN ('schema_migrations', '_schema_graph')
                           AND NOT EXISTS (SELECT 1 FROM pg_attribute x
                                            WHERE x.attrelid = cc.oid AND x.attname = 'tenant_id'
                                              AND x.attnum > 0 AND NOT x.attisdropped)
                           AND EXISTS (SELECT 1 FROM pg_index ii
                                         JOIN pg_attribute pk ON pk.attrelid = cc.oid
                                              AND pk.attnum = (ii.indkey)[0]
                                         JOIN pg_type pt ON pt.oid = pk.atttypid
                                        WHERE ii.indrelid = cc.oid AND ii.indisprimary
                                          AND ii.indnatts = 1
                                          AND pt.typname IN ('varchar', 'bpchar', 'text')))$der$;

    FOR t IN SELECT * FROM (VALUES
        -- needle, patch, which
        -- The exemptions first. A code table's key IS the value space, so listing it among the
        -- columns that reference one would ask the register to answer its own question - and
        -- currencies.currency_code is the row that makes the difference visible, being the first
        -- code-table key whose name looks like a vocabulary (uom_code and cost_method_code match
        -- none of the shapes below).
        (E'AND c.relname <> ''_schema_graph''::name',
         E'AND c.relname <> ''_schema_graph''::name AND c.oid NOT IN ' || v_derived,
         'the code tables themselves, which §5''s derivation names'),
        (E'ARRAY[''text''::regtype::oid, ''character varying''::regtype::oid]',
         E'ARRAY[''text''::regtype::oid, ''character varying''::regtype::oid, ''bpchar''::regtype::oid]',
         'the type list: char(3) is a code column in this schema and the register could not see it'),
        (E'(_type|_status|_method|_label|_unit|_measure)$|(^|_)status$|(^|_)priority$|(^|_)direction$|(^|_)outcome$',
         E'(_type|_status|_method|_label|_unit|_measure)$|(^|_)status$|(^|_)priority$|(^|_)direction$|(^|_)outcome$|(^|_)currency(_code)?$',
         'the name shape: a currency column is named for what it holds'),
        (E'c.confrelid = ANY (ARRAY[''units_of_measure''::regclass::oid, ''costing_methods''::regclass::oid])',
         E'c.confrelid IN ' || v_derived,
         'the code-table set: derived, so a third lookup table cannot be missing from an array'),
        (E'FROM costing_methods',
         E'FROM costing_methods\n        UNION ALL\n         SELECT ''currencies''::regclass::text, '
         || E'array_agg(currencies.currency_code::text ORDER BY currencies.currency_code) '
         || E'FROM currencies',
         'the value-listing arm, which must keep up with the derivation (probe J watches it)')
    ) AS n(needle, patch, which)
    LOOP
        v_hits := array_length(string_to_array(v_body, t.needle), 1) - 1;
        IF v_hits <> 1 THEN
            RAISE EXCEPTION 'the % needle matched % times in the live definition of '
                            'vw_domain_vocabulary - the transform assumes exactly one, and the '
                            'rendering it was written against has changed',
                t.which, v_hits;
        END IF;
        v_new := replace(v_body, t.needle, t.patch);
        IF v_new = v_body THEN
            RAISE EXCEPTION 'the % patch did not apply', t.which;
        END IF;
        v_body := v_new;
    END LOOP;

    EXECUTE 'CREATE OR REPLACE VIEW public.vw_domain_vocabulary AS ' || v_new;
    -- The captured comment is kept and extended rather than replaced: this view's prose is 0007's
    -- account of why each column is constrained the way it is, and rewriting it here would lose
    -- that. What gets added is the fact that the candidate set now includes char(3) codes.
    v_comment := coalesce(v_comment, '') ||
        ' Candidate set widened by 0018: char(3) code columns count now (the currency columns '
        'were invisible to a register that looked only at text and varchar, while verify.sh''s '
        'B18 asked the same incomplete question beside it), the code tables are derived rather '
        'than named, and the name shapes gained the currency axis. Every row this view had before '
        'is unchanged.';
    EXECUTE format('COMMENT ON VIEW public.vw_domain_vocabulary IS %L', v_comment);
    ALTER VIEW public.vw_domain_vocabulary SET (security_invoker = true);

    SELECT string_agg(attname, ',' ORDER BY attnum) INTO v_after
      FROM pg_attribute WHERE attrelid = 'vw_domain_vocabulary'::regclass
        AND attnum > 0 AND NOT attisdropped;
    IF v_after IS DISTINCT FROM v_before THEN
        RAISE EXCEPTION 'the register rewrite changed its columns (% -> %) - only which rows '
                        'qualify was meant to move', v_before, v_after;
    END IF;
    RAISE NOTICE '6.5: vw_domain_vocabulary can now see char(3) code columns and derived code tables';
END
$$;

-- The view §2 added, armed and granted, and the audit-exemption sentence that its comment claims:
-- currencies and currency_rates are global, so 0009's tenant policies do not apply, but B19's
-- declaration list does (verify.sh changes with this file) and 0013's trail cannot - audit_log's
-- tenant_id is NOT NULL, so a global row has no trail to write. Probe L asserts that as a boundary
-- rather than discovering it as a surprise.
ALTER VIEW vw_currency_rates SET (security_invoker = true);
GRANT SELECT ON vw_currency_rates TO afpc_readonly, afpc_auditor;

-- ---------------------------------------------------------------------------
-- 6. Verify by behaving
-- ---------------------------------------------------------------------------
-- §0's five measurements are each reversed by a call rather than by a catalog query, and where a
-- catalog query is the honest form (a ceiling, a trigger, a candidate set) the behaviour is run
-- beside it, because "the typmod says 24,4" and "the receipt that used to crash now lands" are
-- different claims and only the second one is about the door.
DO $$
DECLARE
    v_wh      uuid;
    v_wh2     uuid;
    v_item    uuid;
    v_item2   uuid;
    v_err     text;
    v_txt     text;
    v_num     numeric;
    v_rows    bigint;
    v_n       int := 0;
    v_t2      uuid;
    r         record;
    t         record;
BEGIN
    ------------------------------------------------------------------
    -- A. the master, in the shape the schema already uses for master data. Compared against
    --    units_of_measure rather than against this file's intention: if the two code tables stop
    --    agreeing about what a code table has, the copy §1 claims to have made is a lie.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE c.relname = 'currencies' AND c.relkind = 'r'
          AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                           WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND a.attnum > 0)) <> 1 THEN
        RAISE EXCEPTION 'A failed: currencies is not the global single-key code table §1 says it '
                        'is - tenant-coded, or absent';
    END IF;
    IF (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = 'currencies'::regclass AND a.attname = 'is_active') <>
       (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = 'units_of_measure'::regclass AND a.attname = 'is_active') THEN
        RAISE EXCEPTION 'A failed: currencies and units_of_measure disagree about retirement - '
                        'master data that is deleted instead of deactivated will strand the '
                        'RESTRICT edges 0008 asked for';
    END IF;
    -- 0006's invariant, counted from the catalog rather than trusted from §1's CREATE INDEX lines:
    -- every currency FK column leads an index, and every one of the five edges is RESTRICT.
    IF EXISTS (SELECT 1 FROM pg_constraint c
                WHERE c.contype = 'f' AND c.confrelid = 'currencies'::regclass
                  AND (c.confdeltype <> 'r'
                       OR NOT EXISTS (SELECT 1 FROM pg_index i
                                       WHERE i.indrelid = c.conrelid
                                         AND (c.conkey)[1] = ANY (i.indkey)))) THEN
        RAISE EXCEPTION 'A failed: a currency foreign key is not RESTRICT or does not lead an '
                        'index - % of the five edges are wrong',
            (SELECT count(*) FROM pg_constraint c
              WHERE c.contype = 'f' AND c.confrelid = 'currencies'::regclass
                AND (c.confdeltype <> 'r'
                     OR NOT EXISTS (SELECT 1 FROM pg_index i
                                     WHERE i.indrelid = c.conrelid AND (c.conkey)[1] = ANY (i.indkey))));
    END IF;
    IF (SELECT count(*) FROM pg_constraint WHERE contype='f' AND confrelid='currencies'::regclass)
          <> 5 THEN
        RAISE EXCEPTION 'A failed: % edges point at currencies, not the 5 §1 and §2 add - a '
                        'sixth currency column nobody has read about, or a missing one',
            (SELECT count(*) FROM pg_constraint WHERE contype='f' AND confrelid='currencies'::regclass);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- B. measurement 4, reversed. The three-character space used to be the vocabulary; now
    --    membership is, and the width error that remains is only about length.
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0018-B','0018 probe wh')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('0018-B','0018 probe item','EACH') RETURNING item_id INTO v_item;
    FOREACH v_txt IN ARRAY ARRAY['XYZ', 'xt', 'us', 'zz']
    LOOP
        v_err := NULL;
        BEGIN
            INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                            unit_of_measure, performed_by, currency_code)
                 VALUES ('RECEIPT', v_item, v_wh, 1, 'EACH', '0018 probe', v_txt::char(3));
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLSTATE;
        END;
        IF v_err IS DISTINCT FROM '23503' THEN
            RAISE EXCEPTION 'B failed: currency % answered % - 23503 is the membership answer, '
                            'and ''%'' was accepted into a table with no master to refuse it',
                v_txt, coalesce(v_err, 'a row'), v_txt;
        END IF;
    END LOOP;
    v_err := NULL;
    BEGIN
        INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                        unit_of_measure, performed_by, currency_code)
             VALUES ('RECEIPT', v_item, v_wh, 1, 'EACH', '0018 probe', 'USDT');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '22001' THEN
        RAISE EXCEPTION 'B failed: a four-character code answered % where 22001 is the width '
                        'wall this file leaves exactly as it found it (the membership CHECK lives '
                        'on the master, so a longer string cannot even reach it)',
            coalesce(v_err, 'a row - the column grew, which §1 did not ask for');
    END IF;
    -- The master's own shape rule, which is the only place the code space is stated.
    v_err := NULL;
    BEGIN
        INSERT INTO currencies (currency_code, label, minor_units) VALUES ('usd','lower',2);
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'B failed: the master accepted a lowercase code (% answered) - the shape '
                        'CHECK is on this table for the reason 0007 states: once, not four times',
            coalesce(v_err, 'nothing');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- C. measurement 3, reversed: an item that says JPY produces movements and balances that say
    --    JPY, with no caller naming a currency anywhere.
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0018-C','0018 probe wh')
     RETURNING warehouse_id INTO v_wh2;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure, currency_code)
         VALUES ('0018-C','0018 JPY item','EACH','JPY') RETURNING item_id INTO v_item2;
    PERFORM execute_inventory_movement('RECEIPT', v_item2, NULL::uuid, v_wh2,
             5::numeric, 1000::numeric, '0018 probe', 'PO', NULL::uuid, 'derivation');
    IF (SELECT currency_code FROM inventory_movements
         WHERE item_id = v_item2) IS DISTINCT FROM 'JPY'::char(3) THEN
        RAISE EXCEPTION 'C failed: a movement written without naming a currency says % for an '
                        'item that says JPY - §3b''s derivation did not run, or a caller started '
                        'naming the column itself',
            (SELECT currency_code FROM inventory_movements WHERE item_id = v_item2);
    END IF;
    IF (SELECT cost_currency FROM inventory_on_hand
         WHERE item_id = v_item2 AND warehouse_id = v_wh2) IS DISTINCT FROM 'JPY'::char(3) THEN
        RAISE EXCEPTION 'C failed: the balance the same call created is priced in % - measurement '
                        '3 is unchanged, and average_cost still means nothing',
            (SELECT cost_currency FROM inventory_on_hand
              WHERE item_id = v_item2 AND warehouse_id = v_wh2);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- D. a ledger row keeps its own currency. The derivation reads the item master at insert time
    --    and the result is stored, so repricing an item later changes what the NEXT row says and
    --    not what the last one said: the difference between a stored fact and a join that
    --    rewrites history.
    ------------------------------------------------------------------
    UPDATE inventory_items SET currency_code = 'CHF' WHERE item_id = v_item2;
    IF (SELECT currency_code FROM inventory_movements
         WHERE item_id = v_item2 AND reason_code = 'derivation') IS DISTINCT FROM 'JPY'::char(3) THEN
        RAISE EXCEPTION 'D failed: the earlier movement now reads % - the ledger stopped being '
                        'history and became a view over the item master',
            (SELECT currency_code FROM inventory_movements
              WHERE item_id = v_item2 AND reason_code = 'derivation');
    END IF;
    IF (SELECT cost_currency FROM inventory_on_hand
         WHERE item_id = v_item2 AND warehouse_id = v_wh2) IS DISTINCT FROM 'JPY'::char(3) THEN
        RAISE EXCEPTION 'D failed: the existing balance was renamed to % by a later statement - '
                        'its average_cost was computed in JPY and would now be read as CHF, which '
                        'is measurement 2 with the labels swapped',
            (SELECT cost_currency FROM inventory_on_hand
              WHERE item_id = v_item2 AND warehouse_id = v_wh2);
    END IF;
    -- A balance that does not exist yet takes the item's currency as of now, which is the half
    -- that shows the derivation reads the master at insert time rather than a snapshot of it.
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0018-D','0018 probe wh')
     RETURNING warehouse_id INTO v_wh;
    PERFORM execute_inventory_movement('RECEIPT', v_item2, NULL::uuid, v_wh,
             3::numeric, 900::numeric, '0018 probe', 'PO', NULL::uuid, 'derivation two');
    IF (SELECT cost_currency FROM inventory_on_hand
         WHERE item_id = v_item2 AND warehouse_id = v_wh) IS DISTINCT FROM 'CHF'::char(3) THEN
        RAISE EXCEPTION 'D failed: a new balance for the repriced item took % - the derivation is '
                        'not reading the master at insert time',
            (SELECT cost_currency FROM inventory_on_hand
              WHERE item_id = v_item2 AND warehouse_id = v_wh);
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- E. the rate table's promises, each by the error it produces, and the view's three states:
    --    in force, expired, never quoted.
    ------------------------------------------------------------------
    INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from, source)
         VALUES ('JPY','CHF', 0.17, now() - interval '30 days', '0018 probe');
    v_err := NULL;
    BEGIN
        INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from)
             VALUES ('JPY','CHF', 0.18, now());
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23505' THEN
        RAISE EXCEPTION 'E failed: a second open row for one pair answered % - the partial unique '
                        'index is the whole promise §2 makes about rates, and it is not there',
            coalesce(v_err, 'a row');
    END IF;
    UPDATE currency_rates SET valid_to = now() - interval '1 hour'
     WHERE from_currency = 'JPY' AND to_currency = 'CHF' AND valid_to IS NULL;
    INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from, source)
         VALUES ('JPY','CHF', 0.18, now() - interval '1 hour', '0018 superseded');
    IF (SELECT count(*) FROM vw_currency_rates
         WHERE from_currency = 'JPY' AND to_currency = 'CHF' AND in_force
           AND rate_in_force = 0.18) <> 1 THEN
        RAISE EXCEPTION 'E failed: superseding a rate did not produce one in-force row at 0.18 - '
                        'the view answers %',
            (SELECT coalesce(string_agg(in_force::text || '@' || rate_in_force::text, ','), 'no rows')
               FROM vw_currency_rates WHERE from_currency = 'JPY' AND to_currency = 'CHF');
    END IF;
    -- The three refusals are one shape: a rate that cannot be read. Self-pairs are the interesting
    -- one - identity is 1 by definition, and a stored row that can disagree with arithmetic is a
    -- row that will.
    FOR t IN SELECT * FROM (VALUES
            ('JPY','JPY', 1.0,   '23514', 'a self-pair, which is 1 by definition'),
            ('USD','EUR', 0.0,   '23514', 'a zero rate, which means stock for nothing'),
            ('USD','EUR', -1.0,  '23514', 'a negative rate, which is an inverse nobody asked for')
        ) AS x(a,b,c,code,which)
    LOOP
        v_err := NULL;
        BEGIN
            INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from)
                 VALUES (t.a, t.b, t.c, now());
        EXCEPTION WHEN OTHERS THEN
            v_err := SQLSTATE;
        END;
        IF v_err IS DISTINCT FROM t.code THEN
            RAISE EXCEPTION 'E failed: % answered % instead of % - the rate constraints are what '
                            'makes a hand-entered history trustworthy',
                t.which, coalesce(v_err, 'a row'), t.code;
        END IF;
    END LOOP;
    v_err := NULL;
    BEGIN
        INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from, valid_to)
             VALUES ('EUR','USD', 1.1, now(), now() - interval '1 day');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'E failed: a window that ends before it starts answered % - valid_to > '
                        'valid_from is the difference between history and noise',
            coalesce(v_err, 'a row');
    END IF;
    v_err := NULL;
    BEGIN
        INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from)
             VALUES ('QAT','USD', 1.0, now());
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23503' THEN
        RAISE EXCEPTION 'E failed: a rate for a currency the master does not have answered %',
            coalesce(v_err, 'a row');
    END IF;

    -- The view's three states. Expired and never-quoted are different facts, and a LEFT JOIN that
    -- returns NULL for both is how a rate table stops being trusted.
    UPDATE currency_rates SET valid_to = now() - interval '1 minute'
     WHERE from_currency = 'JPY' AND to_currency = 'CHF' AND valid_to IS NULL;
    IF (SELECT count(*) FROM vw_currency_rates
         WHERE from_currency = 'JPY' AND to_currency = 'CHF'
           AND NOT in_force AND rows_for_pair = 2) <> 1 THEN
        RAISE EXCEPTION 'E failed: a pair whose two rows have both expired is not reported as '
                        'expired-and-known: % - in_force and rows_for_pair are the whole point of '
                        'this view',
            (SELECT coalesce(string_agg(in_force::text || '/' || rows_for_pair::text, ','), 'no rows')
               FROM vw_currency_rates WHERE from_currency = 'JPY' AND to_currency = 'CHF');
    END IF;
    IF (SELECT count(*) FROM vw_currency_rates
         WHERE from_currency = 'GBP' AND to_currency = 'AUD') <> 0 THEN
        RAISE EXCEPTION 'E failed: a pair nobody ever quoted appears in the view, so ''no data'' '
                        'and ''expired'' have stopped being distinguishable';
    END IF;
    -- And the promise §2 does NOT make, shown rather than asserted away: one row that starts
    -- tomorrow leaves today uncovered, and no constraint notices.
    INSERT INTO currency_rates (from_currency, to_currency, rate, valid_from, valid_to)
         VALUES ('GBP','CHF', 1.2, now() + interval '7 days', NULL);
    IF (SELECT count(*) FROM vw_currency_rates
         WHERE from_currency = 'GBP' AND to_currency = 'CHF' AND NOT in_force) <> 1 THEN
        RAISE EXCEPTION 'E failed: the gap case moved - a future-dated open row now reads as in '
                        'force, which means something changed §2''s promise without saying so';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- F. measurement 2, reversed at the door rather than in prose. A balance created through the
    --    door for a EUR item, then a second receipt through the door: both movements and the
    --    balance name EUR, and the average is an average of EUR numbers. The pre-0018 shape - a
    --    EUR-labelled balance taking a USD movement, because the balance's column had no writer and
    --    the ledger's default said USD - is no longer reachable through a door, since both halves
    --    now read the same master. What is left is the case §3b exists for: the item master moving
    --    under a balance that already exists.
    ------------------------------------------------------------------
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0018-F','0018 probe wh')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure, currency_code)
         VALUES ('0018-F','0018 EUR item','EACH','EUR') RETURNING item_id INTO v_item;
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh,
             100::numeric, 10::numeric, '0018 probe', 'PO', NULL::uuid, 'blend one');
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh,
             100::numeric, 12::numeric, '0018 probe', 'PO', NULL::uuid, 'blend two');
    SELECT average_cost, cost_currency INTO v_num, v_txt
      FROM inventory_on_hand WHERE item_id = v_item AND warehouse_id = v_wh;
    IF v_txt IS DISTINCT FROM 'EUR'::char(3) OR v_num <> 11 THEN
        RAISE EXCEPTION 'F failed: two EUR receipts of 10 and 12 average to % in currency % - the '
                        'arithmetic is the one measurement 2 ran, so a mismatch here is the labels',
            v_num, v_txt;
    END IF;
    -- Now the only path that was left: reprice the item under an existing balance. The door has to
    -- refuse rather than average, and refuse *before* writing - which is 0015's decide-then-touch
    -- shape, and is checked by counting the ledger rows as well as by the SQLSTATE.
    UPDATE inventory_items SET currency_code = 'USD' WHERE item_id = v_item;
    v_err := NULL;
    BEGIN
        PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh,
                 50::numeric, 20::numeric, '0018 probe', 'PO', NULL::uuid, 'blend attempt');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    IF v_err IS DISTINCT FROM '23514' THEN
        RAISE EXCEPTION 'F failed: a CHF-priced item with a EUR balance answered % - measurement 2 '
                        'is still reachable through the door', coalesce(v_err, 'a row');
    END IF;
    IF (SELECT count(*) FROM inventory_movements
         WHERE item_id = v_item AND reason_code = 'blend attempt') <> 0 THEN
        RAISE EXCEPTION 'F failed: the refusal wrote a ledger row anyway - a movement that was '
                        'decided against after being recorded is 4.6''s complaint in a new place';
    END IF;
    IF (SELECT average_cost FROM inventory_on_hand
         WHERE item_id = v_item AND warehouse_id = v_wh) <> 11 THEN
        RAISE EXCEPTION 'F failed: the refused receipt still moved the average to %',
            (SELECT average_cost FROM inventory_on_hand
              WHERE item_id = v_item AND warehouse_id = v_wh);
    END IF;
    UPDATE inventory_items SET currency_code = 'EUR' WHERE item_id = v_item;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- G. the seat, which is where §3's choice of SECURITY INVOKER is actually tested. The helper
    --    is invoker-rights, so from afpc_app the read of inventory_items goes through the wall: an
    --    item in the caller's own tenant derives fine. The interesting half is what a caller that
    --    bypasses the doors meets, and probe G' measures it rather than reasoning about it: a
    --    foreign key check does not apply row security, so the derived code is a real currency and
    --    nothing refuses the row.
    ------------------------------------------------------------------
    INSERT INTO tenants (name, slug) VALUES ('0018 second tenant', 'afpc-0018-t2')
     RETURNING tenant_id INTO v_t2;
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id',
        '00000000-0000-0000-0000-000000000001'::text, true);
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0018-G','0018 probe wh')
     RETURNING warehouse_id INTO v_wh2;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure, currency_code)
         VALUES ('0018-G','0018 app-seat item','EACH','GBP') RETURNING item_id INTO v_item;
    SELECT currency_code INTO v_txt FROM inventory_items WHERE item_id = v_item;
    IF v_txt IS DISTINCT FROM 'GBP'::char(3) THEN
        RAISE EXCEPTION 'G failed: afpc_app could not even write an item''s currency (% is what '
                        'the master kept) - §1''s FK is not the problem, the seat is', v_txt;
    END IF;
    PERFORM execute_inventory_movement('RECEIPT', v_item, NULL::uuid, v_wh2,
             7::numeric, 5::numeric, '0018 probe', 'PO', NULL::uuid, 'app seat');
    SELECT currency_code INTO v_txt FROM inventory_items WHERE item_id = v_item;
    IF (SELECT currency_code FROM inventory_movements WHERE item_id = v_item)
          IS DISTINCT FROM 'GBP'::char(3)
       OR (SELECT cost_currency FROM inventory_on_hand
            WHERE item_id = v_item AND warehouse_id = v_wh2) IS DISTINCT FROM 'GBP'::char(3) THEN
        RAISE EXCEPTION 'G failed: under forced row security the derivation produced % and % '
                        'instead of GBP for both - a DEFAULT that reads a tenant-coded table is a '
                        'different promise from the same call as the owner',
            (SELECT currency_code FROM inventory_movements WHERE item_id = v_item),
            (SELECT cost_currency FROM inventory_on_hand
              WHERE item_id = v_item AND warehouse_id = v_wh2);
    END IF;
    RESET ROLE;

    -- G'. and the boundary of the mechanism, measured rather than wished. A raw INSERT is not a
    --     write path: it names no currency, so the column's own default answers 'USD' for an item
    --     priced in yen, in a tenant the caller cannot even see. Nothing refuses - the foreign key
    --     cannot notice (a FK check does not apply row security, and USD is a real currency), and
    --     the derivation lives in the doors, not in the column. This is exactly what §0 means by
    --     preferring a census to a claim: the balance half of the drift is refused at the next
    --     movement (§3b) and every disagreement is counted by probe K; the ledger half is visible
    --     only to whoever reads a row beside its item, which is why the item master needs a
    --     creation door of its own (Obligations-0018) rather than another CHECK.
    SET LOCAL ROLE afpc_app;
    PERFORM set_config('app.tenant_id', v_t2::text, true);
    v_err := NULL;
    BEGIN
        INSERT INTO inventory_movements (movement_type, item_id, to_warehouse_id, quantity,
                                        unit_of_measure, performed_by, reason_code)
             VALUES ('RECEIPT', v_item, v_wh2, 1, 'EACH', '0018 probe', 'bypass');
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLSTATE;
    END;
    SELECT count(*), max(currency_code)::text INTO v_rows, v_txt
      FROM inventory_movements WHERE item_id = v_item AND reason_code = 'bypass';
    RESET ROLE;
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'G'' failed: a raw insert against an invisible item answered % - the '
                        'assertion below is about what it WRITES, not about a refusal, so a '
                        'constraint that has appeared here changed the mechanism §0 describes',
            v_err;
    END IF;
    IF v_rows <> 1 OR v_txt <> 'USD' THEN
        RAISE EXCEPTION 'G'' failed: the bypass wrote % row(s) in currency % - §0''s census claim '
                        'depends on a raw write being possible and visible, not impossible',
            v_rows, coalesce(v_txt, 'nothing');
    END IF;
    DELETE FROM inventory_movements WHERE reason_code = 'bypass';
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- H. the two claims §1 makes about minor_units, both read from the catalog: the constraint's
    --    ceiling has to be the money columns' scale, and a currency with zero minor units has to
    --    be recorded as such (a column nothing reads is a decoration, and this one bounds a type).
    ------------------------------------------------------------------
    IF (SELECT max(minor_units) FROM currencies) >
       (SELECT min(a.atttypmod % 65536)::int / 1 FROM pg_attribute a
         WHERE a.attrelid = 'inventory_on_hand'::regclass AND a.attname = 'average_cost') THEN
        RAISE EXCEPTION 'H failed: a currency needs % minor digits while money carries % - the '
                        'money columns have to be widened before the master can be',
            (SELECT max(minor_units) FROM currencies),
            (SELECT numeric_scale FROM information_schema.columns
              WHERE table_name = 'inventory_on_hand' AND column_name = 'average_cost');
    END IF;
    IF (SELECT minor_units FROM currencies WHERE currency_code = 'JPY') <> 0 THEN
        RAISE EXCEPTION 'H failed: JPY''s minor_units is % - the column is stored to be read, and '
                        'the row that proves it is read here',
            (SELECT minor_units FROM currencies WHERE currency_code = 'JPY');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- I. measurement 1, reversed: the receipt that died of 22003 lands, and the ceiling is sized
    --    from the arithmetic rather than from either factor. Structural and behavioural forms of
    --    the same claim, because the typmod is a promise and the INSERT is the evidence.
    ------------------------------------------------------------------
    IF (SELECT numeric_precision || ',' || numeric_scale FROM information_schema.columns
         WHERE table_name = 'inventory_movements' AND column_name = 'total_cost') <> '24,4' THEN
        RAISE EXCEPTION 'I failed: total_cost is numeric(%) - §4 sizes it from a product of two '
                        '12-digit columns, so anything narrower re-creates measurement 1',
            (SELECT numeric_precision || ',' || numeric_scale FROM information_schema.columns
              WHERE table_name = 'inventory_movements' AND column_name = 'total_cost');
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'public' AND data_type = 'numeric'
           AND numeric_precision = 18 AND numeric_scale = 4
           AND table_name || '.' || column_name = ANY (ARRAY[
               'inventory_items.standard_cost','inventory_items.last_cost',
               'inventory_movements.unit_cost','inventory_on_hand.average_cost'])) <> 4 THEN
        RAISE EXCEPTION 'I failed: % of the four money columns is numeric(18,4)',
            (SELECT count(*) FROM information_schema.columns
              WHERE table_schema = 'public' AND data_type = 'numeric'
                AND numeric_precision = 18 AND numeric_scale = 4
                AND table_name || '.' || column_name = ANY (ARRAY[
                    'inventory_items.standard_cost','inventory_items.last_cost',
                    'inventory_movements.unit_cost','inventory_on_hand.average_cost']));
    END IF;
    -- Quantities deliberately unchanged: the finding is that the two axes shared a precision, not
    -- that a stock ceiling was too small. Asserted so a later "consistency" widening cannot quietly
    -- let a balance claim 1e17 units.
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'public' AND data_type = 'numeric'
           AND numeric_precision = 12 AND numeric_scale = 4
           AND column_name ~ '^quantity_|_quantity$|reserved_quantity|reorder_point|safety_stock')
          < 8 THEN
        RAISE EXCEPTION 'I failed: only % quantity columns are still numeric(12,4) - money moved '
                        'and stock should not have',
            (SELECT count(*) FROM information_schema.columns
              WHERE table_schema = 'public' AND data_type = 'numeric'
                AND numeric_precision = 12 AND numeric_scale = 4
                AND column_name ~ '^quantity_|_quantity$|reserved_quantity|reorder_point|safety_stock');
    END IF;
    INSERT INTO warehouses (warehouse_code, name) VALUES ('0018-I','0018 probe wh')
     RETURNING warehouse_id INTO v_wh;
    INSERT INTO inventory_items (sku, name, base_unit_of_measure)
         VALUES ('0018-I','0018 big item','EACH') RETURNING item_id INTO v_item2;
    PERFORM execute_inventory_movement('RECEIPT', v_item2, NULL::uuid, v_wh,
             1000000::numeric, 1000000::numeric, '0018 probe', 'PO', NULL::uuid, 'ceiling');
    IF (SELECT total_cost FROM inventory_movements
         WHERE item_id = v_item2 AND reason_code = 'ceiling') <> 1000000000000 THEN
        RAISE EXCEPTION 'I failed: the receipt measurement 1 killed wrote total_cost %',
            (SELECT total_cost FROM inventory_movements
              WHERE item_id = v_item2 AND reason_code = 'ceiling');
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- J. the register, from both sides. The currency columns appear with the code table's own
    --    values, and the set of tables §5 derives is exactly the set it can list values for - the
    --    0015 lesson that a derived set and a hand-written UNION are two rules until a probe says
    --    they are one.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_rows FROM vw_domain_vocabulary
     WHERE (table_name, column_name) IN (('inventory_items','currency_code'),
                                        ('inventory_movements','currency_code'),
                                        ('inventory_on_hand','cost_currency'))
       AND enforced_by = 'lookup table' AND lookup_table = 'currencies'
       AND cardinality(lookup_values) = (SELECT count(*) FROM currencies);
    IF v_rows <> 3 THEN
        RAISE EXCEPTION 'J failed: % of the three currency columns are in the register as a '
                        'lookup-table answer - measurement 5 said the register could not see a '
                        'char(3), and §5 widened it rather than converting the columns', v_rows;
    END IF;
    IF EXISTS (SELECT 1 FROM vw_domain_vocabulary WHERE reason LIKE 'UNDECIDED%') THEN
        RAISE EXCEPTION 'J failed: widening the candidate set surfaced a column with neither a '
                        'constraint nor a recorded reason - B2 will say so too, but this file '
                        'opened the hole';
    END IF;
    -- The agreement between §5's derivation and its value-listing branch.
    SELECT count(*) INTO v_rows FROM (
        SELECT DISTINCT confrelid FROM pg_constraint
         WHERE contype = 'f' AND confrelid::regclass::text = ANY (
             SELECT lookup_table FROM vw_domain_vocabulary WHERE enforced_by = 'lookup table')
        ) x
     WHERE NOT EXISTS (SELECT 1 FROM vw_domain_vocabulary v
                        WHERE v.enforced_by = 'lookup table'
                          AND v.lookup_table = x.confrelid::regclass::text
                          AND v.lookup_values IS NOT NULL);
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'J failed: % code table(s) the register names as an answer have no '
                        'value-listing branch - §5''s UNION is behind §5''s derivation, which is '
                        'the failure mode a derived set is supposed to prevent', v_rows;
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- K. the reconciliation report a populated deployment would need, expressed as a census rather
    --    than a fix: balances whose stored currency disagrees with their item master. Zero on a
    --    database where every row came through the door after §3, and a number rather than a
    --    silence anywhere else. The probes' own fixtures are excluded, because probes C, D and F
    --    deliberately manufacture drift to prove §3b refuses it - counting them would make this
    --    NOTICE print on a clean database, and a report that always says "1" is not a report.
    ------------------------------------------------------------------
    SELECT count(*) INTO v_rows FROM inventory_on_hand h
      JOIN inventory_items i ON i.item_id = h.item_id
     WHERE h.cost_currency IS DISTINCT FROM i.currency_code
       AND i.sku NOT LIKE '0018-%';
    IF v_rows > 0 THEN
        RAISE NOTICE '6.5 NOTE % balance rows disagree with their item''s currency - §3 derives '
                     'them and does not rewrite them, so this is the reconciliation a populated '
                     'deployment owns (Obligations-0018)', v_rows;
    END IF;
    -- And the manufactured drift is real, which is the half that makes the exclusion honest rather
    -- than a way of making the number go away.
    IF (SELECT count(*) FROM inventory_on_hand h
          JOIN inventory_items i ON i.item_id = h.item_id
         WHERE h.cost_currency IS DISTINCT FROM i.currency_code
           AND i.sku LIKE '0018-%') = 0 THEN
        RAISE EXCEPTION 'K failed: no probe fixture disagrees with its item, so the exclusion above '
                        'hides nothing and probes C and D are not building the case they claim to';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- L. the trail boundary §2's comment claims. audit_log.tenant_id is NOT NULL, so a global row
    --    has nowhere to be trailed from: not an oversight to fix here but an asymmetry to say out
    --    loud, because retiring a currency is exactly the kind of quiet structural change 0013 was
    --    written to make loud.
    ------------------------------------------------------------------
    UPDATE currencies SET is_active = false WHERE currency_code = 'INR';
    IF EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'currencies') THEN
        RAISE EXCEPTION 'L failed: something is trailing the global master table currencies, '
                        'which has no tenant to file the row under - audit_log''s NOT NULL is what '
                        'makes that impossible, so a trail appearing means the constraint moved';
    END IF;
    IF (SELECT count(*) FROM vw_audit_coverage WHERE table_name = 'currencies') <> 0 THEN
        RAISE EXCEPTION 'L failed: vw_audit_coverage lists currencies, so the coverage view''s '
                        'scope is no longer the tenant-coded set §2 says it is';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'audit_log' AND column_name = 'tenant_id'
           AND is_nullable = 'NO') <> 1 THEN
        RAISE EXCEPTION 'L failed: audit_log.tenant_id is nullable, and this file has just '
                        'discovered that global rows could have been trailed all along - the '
                        'decision belongs in the migration that widens 0013, not here';
    END IF;
    UPDATE currencies SET is_active = true WHERE currency_code = 'INR';
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- M. 0010's rule, applied to the two tables this file adds: a mutable table with updated_at
    --    has the touch trigger, and the trigger is observable rather than assumed.
    ------------------------------------------------------------------
    IF (SELECT count(*) FROM pg_trigger tr
         JOIN pg_class c ON c.oid = tr.tgrelid
        WHERE tr.tgname = 'afpc_touch_updated_at'
          AND c.relname IN ('currencies','currency_rates')) <> 2 THEN
        RAISE EXCEPTION 'M failed: % of the two new tables carries the touch trigger - 0007 '
                        'found tables whose updated_at lied, and a new code table is the place '
                        'that repeats it. (The alias is tr because this block already has a '
                        'record named t, and a plpgsql name inside a query means the variable.)',
            (SELECT count(*) FROM pg_trigger tr JOIN pg_class c ON c.oid = tr.tgrelid
              WHERE tr.tgname = 'afpc_touch_updated_at'
                AND c.relname IN ('currencies','currency_rates'));
    END IF;
    -- 0010's promise has two halves, and both are testable inside one transaction even though
    -- now() does not advance within it (the first draft of this probe asked "did it move" and
    -- failed on the transaction timestamp, not on the trigger). A caller that names updated_at is
    -- believed - that is the backfill shape the function's comment defends - and a caller that
    -- does not is stamped.
    UPDATE currencies SET updated_at = '2000-01-01+00' WHERE currency_code = 'EUR';
    IF (SELECT updated_at FROM currencies WHERE currency_code = 'EUR')
          IS NOT DISTINCT FROM now() THEN
        RAISE EXCEPTION 'M failed: an explicit updated_at was overwritten with % - 0010 chose to '
                        'honour a caller that dates a row itself, and a trigger that stomps it '
                        'makes every backfill a lie',
            now();
    END IF;
    UPDATE currencies SET label = 'Euro' WHERE currency_code = 'EUR';
    IF (SELECT updated_at FROM currencies WHERE currency_code = 'EUR')
          IS DISTINCT FROM now() THEN
        RAISE EXCEPTION 'M failed: an update that named no updated_at left the row at % - the '
                        'touch trigger is not installed on the table, which is the whole of 6.3 '
                        'applied to a table this file added',
            (SELECT updated_at FROM currencies WHERE currency_code = 'EUR');
    END IF;
    IF (SELECT count(*) FROM pg_class WHERE relname IN ('vw_currency_rates')) <> 1 THEN
        RAISE EXCEPTION 'M failed: vw_currency_rates is not installed';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c WHERE c.relname = 'vw_currency_rates'
                AND coalesce(array_to_string(c.reloptions, ','), '')
                    NOT LIKE '%security_invoker=true%') THEN
        RAISE EXCEPTION 'M failed: vw_currency_rates would run as its owner, which is 0009''s '
                        'note about a view skipping the wall';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- N. where the rule lives, said as a set of places rather than as a hope. §0 rejected the column
--    default (PostgreSQL forbids a column reference in one, measured) and §3 rejected a trigger
--    (it cannot tell an unset column from a value someone meant). What is left is the two doors and
--    one helper, and the claim worth guarding is that the rule has exactly that many homes: a
--    third caller of afpc_item_currency is a new write path that needed it, and a second formula
--    inside a door is the copy nobody read.
    ------------------------------------------------------------------
    IF (SELECT string_agg(proname, ',' ORDER BY proname) FROM pg_proc p
         JOIN pg_namespace ns ON ns.oid = p.pronamespace
        WHERE ns.nspname = 'public' AND p.prokind = 'f'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
          AND pg_get_functiondef(p.oid) LIKE '%afpc_item_currency(%')
          IS DISTINCT FROM 'afpc_item_currency,execute_inventory_movement,reserve_inventory_for_order' THEN
        RAISE EXCEPTION 'N failed: the currency derivation is called from (%) - §3 and §3b put it '
                        'in the two doors that write money and nowhere else',
            (SELECT coalesce(string_agg(proname, ','), 'nothing') FROM pg_proc p
              JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.prokind = 'f'
               AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
               AND pg_get_functiondef(p.oid) LIKE '%afpc_item_currency(%');
    END IF;
    IF (SELECT position('v_currency := afpc_item_currency(p_item_id)' IN prosrc)
          FROM pg_proc WHERE proname = 'execute_inventory_movement') = 0
       OR (SELECT (array_length(string_to_array(prosrc, 'afpc_item_currency(p_item_id)'), 1) - 1)
             FROM pg_proc WHERE proname = 'reserve_inventory_for_order') <> 1 THEN
        RAISE EXCEPTION 'N failed: a door does not read the helper the way §3b wrote it to - the '
                        'transform ran on text that was discarded, or a later edit replaced the '
                        'call with a formula';
    END IF;
    -- The signatures did not move: §3 considered adding a currency parameter and rejected it,
    -- because a parameter a caller can leave out is the same lie with an extra doorbell.
    IF array_length((SELECT proargtypes::int[] FROM pg_proc
                      WHERE proname = 'execute_inventory_movement'), 1) <> 14
       OR array_length((SELECT proargtypes::int[] FROM pg_proc
                        WHERE proname = 'reserve_inventory_for_order'), 1) <> 8
       OR (SELECT count(*) FROM pg_proc WHERE proname IN
                ('execute_inventory_movement','reserve_inventory_for_order')) <> 2 THEN
        RAISE EXCEPTION 'N failed: a door''s signature or head count moved - §3b deliberately added '
                        'no parameter, so a new one is a decision made inside a guard clause';
    END IF;
    v_n := v_n + 1;

    ------------------------------------------------------------------
    -- Cleanup. The probe rows are inventory facts, so the order is 0008's RESTRICT chain: ledger
    -- and balances before items, and the rates before the currencies they name. The seed currencies
    -- stay: they are master data this migration installs, not residue.
    ------------------------------------------------------------------
    DELETE FROM currency_rates;
    DELETE FROM inventory_reservations WHERE item_id IN
        (SELECT item_id FROM inventory_items WHERE sku LIKE '0018-%');
    DELETE FROM inventory_movements WHERE item_id IN
        (SELECT item_id FROM inventory_items WHERE sku LIKE '0018-%');
    DELETE FROM inventory_on_hand WHERE item_id IN
        (SELECT item_id FROM inventory_items WHERE sku LIKE '0018-%');
    DELETE FROM inventory_items WHERE sku LIKE '0018-%';
    DELETE FROM warehouses WHERE warehouse_code LIKE '0018-%';
    DELETE FROM idempotency_keys WHERE operation IN ('execute_inventory_movement','reserve_inventory_for_order');
    DELETE FROM tenants WHERE slug = 'afpc-0018-t2';

    IF v_n <> 14 THEN
        RAISE EXCEPTION 'expected 14 behavioural verifications, completed %', v_n;
    END IF;
    RAISE NOTICE '6.5: % checks passed - the currency a cost is in has a master to name it, one '
                 'place to be read from, and a register that can see it; a product of two '
                 '1e8-scale numbers no longer crashes the ledger; the averaging door refuses to '
                 'blend; and the rate history answers in force, expired, and never quoted without '
                 'translating anything', v_n;
END
$$;
