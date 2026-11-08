// Package inventory is the inventory agent's tool surface: reads that name the vw_* views the
// schema publishes (ADR-003) and exactly one write, which is a call to the reservation door
// (ADR-002). No file here composes an INSERT, and the reads compose WHERE clauses only against
// view columns - a state the views cannot express is a state this agent must not pretend to see.
package inventory

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"encoding/json"
	"jada-backend/pkg/tools"
	"jada-backend/pkg/turn"
)

// Querier is the whole of the database this package needs - identical in shape to the customer
// service agent's, for the identical reasons: a fake is cheap, and there is no Exec in the
// interface, so a write that is not a door cannot be composed here at all.
type Querier interface {
	// Query runs a SELECT and returns rows as generic values.
	Query(ctx context.Context, sql string, args ...any) ([]map[string]any, error)
	// Call invokes a stored function by name with positional arguments.
	Call(ctx context.Context, name string, args []any) ([]map[string]any, error)
}

// This process's name in the trail, one value in two columns (see the customer service agent's
// note on the same fact).
const (
	EnvAgentRole     = "AGENT_ROLE"
	DefaultAgentRole = "inventory"
)

// Row caps. Same reasoning as the CRM's: a model with a context window gets a bounded answer and
// a pointer to narrow, never a truncation that looks like the whole truth.
const (
	defaultItemRows = 20
	maxItemRows     = 200
)

// Tools is the agent's inventory surface: four reads and one door.
//
// execute_inventory_movement is deliberately absent. It is the door that would let this agent
// *create* stock history, and a monitoring agent that can move stock can silence its own alarms
// by shifting a number; the requirements doc says the same thing about `orders` in the vocabulary
// it had. Reservation is the one commitment this agent is trusted with, because its failure mode
// is a refusal, not a falsified history.
func Tools(q Querier) []tools.ToolDefinition {
	if q == nil {
		return nil
	}
	return []tools.ToolDefinition{
		getLowStockItems(q),
		getItemAvailability(q),
		getItemMovementSummary(q),
		getInventoryValuation(q),
		reserveInventory(q),
	}
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

func getLowStockItems(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_low_stock_items",
		Description: "The shortage list: every item at every warehouse whose available quantity " +
			"is at or below its reorder point, with the view's own verdict in alert_level (LOW or " +
			"CRITICAL - CRITICAL is the schema's, not this tool's opinion), the quantity on hand, " +
			"available, and in transit, the reorder point, safety stock, lead time in days, and " +
			"stock_percentage as available against the point. Optional alert_level, category and " +
			"warehouse_id narrow the list. suggested_shortfall is added here: available subtracted " +
			"from the reorder point - the quantity that would bring the line back to threshold. " +
			"The item master's preferred purchase quantity lives behind no view, so this is a " +
			"shortfall and not a PO line. An empty list is good news, not a failure.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"alert_level":  text("LOW or CRITICAL; anything else the other verdict would silence."),
			"category":     text("Category name, case-insensitive substring."),
			"warehouse_id": text("A warehouse id (uuid) to confine the list to one building."),
			"limit":        integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultItemRows, 1, maxItemRows)
			if err != nil {
				return "", err
			}

			where, vals := []string{"true"}, []any{}
			add := func(clause string, v any) {
				sql, took := clauseFor(clause, len(vals)+1)
				where = append(where, sql)
				if took {
					vals = append(vals, v)
				}
			}
			if lvl := str(args, "alert_level"); lvl != nil {
				L := strings.ToUpper(lvl.(string))
				if L != "LOW" && L != "CRITICAL" {
					return "", fmt.Errorf("alert_level is LOW or CRITICAL, got %q", lvl)
				}
				add("alert_level = ?", L)
			}
			if cat := str(args, "category"); cat != nil {
				add("category_name ILIKE ?", "%"+cat.(string)+"%")
			}
			if wh, err := uuidArg(args, "warehouse_id"); err != nil {
				return "", err
			} else if wh != nil {
				add("warehouse_id = ?", wh)
			}

			sql := "SELECT item_id, sku, name, warehouse_id, warehouse_name, quantity_on_hand," +
				" quantity_available, quantity_in_transit, reorder_point, safety_stock," +
				" lead_time_days, alert_level, stock_percentage" +
				" FROM vw_low_stock_alerts WHERE " + strings.Join(where, " AND ") +
				" ORDER BY stock_percentage, sku LIMIT $" + strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			for _, r := range rows {
				r["suggested_shortfall"] = shortfall(r)
			}
			return Rows(withNote(rows, "nothing is below its reorder point right now"))
		},
	}
}

func getItemAvailability(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_item_availability",
		Description: "Where stock actually is: per item and warehouse, quantity_on_hand minus " +
			"reservations equals quantity_available, plus what is in transit, with the reorder " +
			"thresholds, bin (location) detail, expiry for lot-controlled stock, average cost " +
			"with its currency, stock_status and needs_reorder. Name the item with item_id or sku " +
			"(exact, as stored), optionally one warehouse_id; ask neither and you get a bounded " +
			"list of every stocked line. Reserved quantity is committed and not issuable - " +
			"available, not on hand, is the number a promise is measured against.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"item_id":           text("The item's uuid."),
			"sku":               text("The exact SKU as stored."),
			"warehouse_id":      text("A warehouse id (uuid)."),
			"only_need_reorder": boolean("True to return just the lines where needs_reorder holds."),
			"limit":             integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultItemRows, 1, maxItemRows)
			if err != nil {
				return "", err
			}

			where, vals := []string{"true"}, []any{}
			add := func(clause string, v any) {
				sql, took := clauseFor(clause, len(vals)+1)
				where = append(where, sql)
				if took {
					vals = append(vals, v)
				}
			}
			if id, err := uuidArg(args, "item_id"); err != nil {
				return "", err
			} else if id != nil {
				add("item_id = ?", id)
			}
			if sku := str(args, "sku"); sku != nil {
				add("sku = ?", sku)
			}
			if wh, err := uuidArg(args, "warehouse_id"); err != nil {
				return "", err
			} else if wh != nil {
				add("warehouse_id = ?", wh)
			}
			if b, _ := boolArg(args, "only_need_reorder", false).(bool); b {
				// Through add() rather than straight into `where`, so that every clause this package
				// builds passes the one builder that knows the rule: a fragment with nothing to bind
				// contributes no argument (clauseFor in args.go, and agents/sales'
				// TestNoQuerySendsAParameterItsSQLNeverNames for the version a build enforces). This form
				// was already right on its own; two spellings of "add a condition" is how one of them
				// drifts, and in the sales fork one of them did.
				add("needs_reorder", nil)
			}

			sql := "SELECT item_id, sku, name, warehouse_id, warehouse_name, location_code," +
				" quantity_on_hand, quantity_available, quantity_reserved, quantity_in_transit," +
				" reorder_point, safety_stock, stock_status, needs_reorder, average_cost," +
				" cost_currency" +
				" FROM vw_item_availability WHERE " + strings.Join(where, " AND ") +
				" ORDER BY sku, warehouse_name LIMIT $" + strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "no stock lines matched - an unrecognised sku reads the "+
				"same way, so check the spelling before concluding the item does not exist"))
		},
	}
}

func getItemMovementSummary(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_item_movement_summary",
		Description: "One item's movement history by day and type within a window (7-90 days, " +
			"default 30): net_quantity, counts, inbound and outbound totals, average unit cost - " +
			"and days_of_supply, this tool's one derived opinion: available stock divided by the " +
			"window's mean daily outbound. RESERVATION rows make stock unavailable without moving " +
			"it, so inbound and outbound totals exclude them while net_quantity counts them. An " +
			"item with no outbound history answers days_of_supply=null, which is UNKNOWN - not " +
			"infinite, and not the zero that would say demand stopped.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"item_id": text("The item's uuid. One of item_id or sku."),
			"sku":     text("The exact SKU. One of item_id or sku."),
			"days":    integer("Window in days, 7-90. Default 30."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			window, err := clampInt(args, "days", 30, 7, 90)
			if err != nil {
				return "", err
			}

			itemID, err := uuidArg(args, "item_id")
			if err != nil {
				return "", err
			}
			sku := str(args, "sku")
			if itemID == nil && sku == nil {
				return "", fmt.Errorf("name the item: item_id or sku")
			}
			if itemID == nil {
				// sku resolves through the availability view, not the item table: the rule is
				// that reads name views, and this view carries the sku column it would JOIN for.
				rows, err := q.Query(ctx,
					"SELECT DISTINCT item_id FROM vw_item_availability WHERE sku = $1 LIMIT 1", sku)
				if err != nil {
					return "", err
				}
				if len(rows) == 0 {
					return "", fmt.Errorf("no stock lines carry sku %q - an item with zero "+
						"movements and no on-hand row is invisible to the ledger views too", sku)
				}
				itemID = rows[0]["item_id"]
			}

			history, err := q.Query(ctx,
				"SELECT movement_date, movement_type, net_quantity, movement_count,"+
					" avg_unit_cost, total_inbound, total_outbound"+
					" FROM vw_item_movement_summary"+
					" WHERE item_id = $1 AND movement_date >= current_date - make_interval(days => $2::int)"+
					" ORDER BY movement_date DESC LIMIT 200", itemID, window)
			if err != nil {
				return "", err
			}

			// The available total for days_of_supply, again from a view. SUM across warehouses:
			// the commitment the ratio informs is answerable from any bin, and the per-warehouse
			// breakdown is already in the history rows' own shape.
			var avail *float64
			sumRows, err := q.Query(ctx,
				"SELECT coalesce(sum(quantity_available), 0) AS avail"+
					" FROM vw_item_availability WHERE item_id = $1", itemID)
			if err == nil && len(sumRows) > 0 {
				if a, ok := num(sumRows[0]["avail"]); ok {
					avail = &a
				}
			}

			out := map[string]any{
				"item_id": itemID, "window_days": window, "history": history,
				"days_of_supply": daysOfSupply(history, window, avail),
			}
			if out["days_of_supply"] == nil {
				out["velocity_note"] = "no outbound in the window: days of supply is unknown, " +
					"not infinite - say so rather than dividing"
			}
			return Rows([]map[string]any{out})
		},
	}
}

func getInventoryValuation(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_inventory_valuation",
		Description: "Inventory value by warehouse and category, per currency: unique items, " +
			"total units, total_value at average cost, and available_value counting only issuable " +
			"quantity. Nothing converts: a holding with a USD line and a JPY line answers as two " +
			"rows, because the schema declined to make the conversion, and summing across that " +
			"decision would be this tool inventing a rate. Optional warehouse_id or category.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"warehouse_id": text("A warehouse id (uuid)."),
			"category":     text("Category name, case-insensitive substring."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			where, vals := []string{"true"}, []any{}
			add := func(clause string, v any) {
				sql, took := clauseFor(clause, len(vals)+1)
				where = append(where, sql)
				if took {
					vals = append(vals, v)
				}
			}
			if wh, err := uuidArg(args, "warehouse_id"); err != nil {
				return "", err
			} else if wh != nil {
				add("warehouse_id = ?", wh)
			}
			if cat := str(args, "category"); cat != nil {
				add("category_name ILIKE ?", "%"+cat.(string)+"%")
			}

			rows, err := q.Query(ctx,
				"SELECT warehouse_name, category_name, currency_code, unique_items, total_units,"+
					" total_value, available_value"+
					" FROM vw_inventory_valuation WHERE "+strings.Join(where, " AND ")+
					" ORDER BY warehouse_name, category_name", vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "no valuation rows: with nothing on hand, there is nothing to value"))
		},
	}
}

// ---------------------------------------------------------------------------
// The write door
// ---------------------------------------------------------------------------

func reserveInventory(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "reserve_inventory",
		Description: "Commit stock to a document: reserves quantity of item_id at warehouse_id " +
			"against order_id, typed by order_type - PURCHASE, SALES, WORK, TRANSFER or STOCK (an " +
			"internal hold). Answers status SUCCESS with the reservation_id, or INSUFFICIENT_STOCK " +
			"with how much was actually available across every bin in that warehouse - that " +
			"refusal is the door's verdict, and an identical retry will not change it: only " +
			"restock does. A nonexistent item or warehouse, a non-positive quantity, or an order " +
			"type outside the list is an error and not a shortage: one says the shelf is empty, " +
			"the other says the wrong question was asked, and the human in the loop needs to be " +
			"told which - and since 0030, a document-typed hold that names a uuid no order answers to " +
			"is a third case: an error, and a new one, because the column used to accept anything. " +
			"reserved_by should name who the hold is for. Releasing a hold is not this tool's job and " +
			"no longer needs to be nobody's: cancel_inventory_reservation is 0030's door and the sales " +
			"agent registers it.",
		Policy: tools.ToolPolicy{ReadOnly: false},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"item_id":      text("The item's uuid, from get_item_availability or get_low_stock_items. Required."),
				"warehouse_id": text("The warehouse's uuid. Required."),
				"quantity":     integer("Whole units to reserve; must be positive. Required."),
				"order_type":   text("PURCHASE, SALES, WORK, TRANSFER or STOCK. Required."),
				"order_id": text("The document's uuid. Required for SALES, PURCHASE and WORK, and " +
					"it must name an order that EXISTS and is of that type: 0030's enforcement " +
					"refuses a commitment against a document that is not there, which is the rule " +
					"thirteen units on this server sat in violation of. Omit it for STOCK and for " +
					"TRANSFER, the two types that name no document table and no such table exists."),
				"reserved_by": text("Who the hold is for; defaults to this agent's role."),
			})
			p["required"] = []string{"item_id", "warehouse_id", "quantity", "order_type"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			itemID, err := uuidArg(args, "item_id")
			if err != nil {
				return "", err
			}
			if itemID == nil {
				return "", fmt.Errorf("item_id is required - name the item to reserve")
			}
			whID, err := uuidArg(args, "warehouse_id")
			if err != nil {
				return "", err
			}
			if whID == nil {
				return "", fmt.Errorf("warehouse_id is required - the door will not guess which bin to promise from")
			}
			qty, err := days(args, "quantity", 0)
			if err != nil {
				return "", err
			}
			if qty <= 0 {
				return "", fmt.Errorf("quantity must be positive, got %v", args["quantity"])
			}
			orderType := str(args, "order_type")
			if orderType == nil {
				return "", fmt.Errorf("order_type is required: PURCHASE, SALES, WORK, TRANSFER or STOCK")
			}
			orderType = strings.ToUpper(orderType.(string))
			orderID, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			reservedBy := strDefault(args, "reserved_by", AgentName())

			resolved := []any{itemID, whID, int64(qty), orderType, orderID, reservedBy}

			// The claim key goes last, after the door's optional location - the order its
			// signature has them in, and TestClaimsAreLast keeps the Go call honest about it.
			rows, err := q.Call(ctx, "reserve_inventory_for_order",
				append(resolved, nil, key(ctx, "reserve_inventory", resolved)))
			if err != nil {
				return "", err
			}
			if len(rows) == 0 {
				return "", fmt.Errorf("reserve_inventory_for_order returned no row: the operation did not happen")
			}

			row := rows[0]
			status, _ := row["status"].(string)
			switch status {
			case "SUCCESS":
				turn.Source(ctx, "inventory_reservations", row["reservation_id"])
				slog.Info("stock reserved", "item_id", itemID, "warehouse_id", whID,
					"quantity", qty, "order_type", orderType, "reservation_id", row["reservation_id"])
			case "INSUFFICIENT_STOCK":
				slog.Info("reservation refused", "item_id", itemID, "quantity", qty,
					"message", row["message"])
			default:
				return "", fmt.Errorf("the door answered %q, which is not one of the two statuses "+
					"it publishes - the contract this tool was written against has changed", status)
			}
			return mustJSON(row)
		},
	}
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

// AgentName is what this process calls itself in the trail, resolved once per call from the
// environment the deployment set.
func AgentName() string {
	if v := strings.TrimSpace(os.Getenv(EnvAgentRole)); v != "" {
		return v
	}
	return DefaultAgentRole
}

// shortfall is the view arithmetic the alert tool advertises: the gap between available and the
// threshold the schema already decided matters. Above the point answers nil, not a negative
// shortage - "no shortfall" and "negative shortfall" are different sentences.
func shortfall(row map[string]any) any {
	a, ok1 := num(row["quantity_available"])
	r, ok2 := num(row["reorder_point"])
	if !ok1 || !ok2 || r-a <= 0 {
		return nil
	}
	return r - a
}

// daysOfSupply divides available stock by the window's mean daily outbound. avail arrives from
// the caller's second read because the history rows are per-day and carry no stock number; nil
// avail or zero outbound answers nil, which every caller must read as unknown.
func daysOfSupply(history []map[string]any, windowDays int, avail *float64) any {
	var out float64
	for _, r := range history {
		if t, ok := num(r["total_outbound"]); ok {
			out += t
		}
	}
	if avail == nil || out <= 0 || windowDays <= 0 {
		return nil
	}
	return round1(*avail / (out / float64(windowDays)))
}

func num(v any) (float64, bool) {
	switch t := v.(type) {
	case int64:
		return float64(t), true
	case int32:
		// int4, which is what an `integer` column is. Every numeric reader in these three forks was
		// written against the shapes a model's JSON arguments produce - float64, and the odd int64 -
		// so a row's int2 or int4 fell through to "not a number", which arrives as a zero rather than
		// as an error. pgx v5's own default map is the list worth copying: it sends int2 as int16,
		// int4 as int32, int8 as int64, float4 as float32, and numeric as pgtype.Numeric
		// (pgtype/pgtype_default.go:163-177).
		return float64(t), true
	case int16:
		return float64(t), true // smallint
	case uint64:
		return float64(t), true
	case float32:
		return float64(t), true // real
	case float64:
		return t, true
	case int:
		return float64(t), true
	case json.Number:
		// What pkg/db hands back for a numeric column since 2026-11-07, when the alternative was
		// noticing that `%v` on pgtype.Numeric prints its four fields - which is what this package's
		// scheduled summary line had been doing, in production, in final_output.
		f, err := strconv.ParseFloat(t.String(), 64)
		if err != nil {
			return 0, false
		}
		return f, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
		if err != nil {
			return 0, false
		}
		return f, true
	default:
		return 0, false
	}
}

func round1(f float64) float64 { return float64(int64(f*10+0.5)) / 10 }

// uuidArg reads a uuid-shaped string argument, nil when absent. Validated here rather than at the
// door so a malformed id is a tool-level error naming its own argument, not a 22P02 from inside a
// function the model has no visibility into. The validation is the shape only - a well-shaped
// string the database has never heard of stays a door problem, and the door answers that one,
// because whether an id exists is the database's fact and not this process's.
func uuidArg(args map[string]any, name string) (any, error) {
	v := str(args, name)
	if v == nil {
		return nil, nil
	}
	s := strings.ToLower(strings.TrimSpace(v.(string)))
	if !isUUIDShape(s) {
		return nil, fmt.Errorf("%s is not a uuid: %q - ids come from the read tools, never from typing",
			name, v)
	}
	return s, nil
}

// isUUIDShape is 8-4-4-4-12 hex, by hand and without importing a library for it: this module has
// exactly one UUID producer (pkg/ids) and adding a dependency to validate what pgx will bind
// anyway is a second definition of "looks like an id" in exchange for nothing.
func isUUIDShape(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
			if !isHex {
				return false
			}
		}
	}
	return true
}

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

func text(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }

func integer(desc string) map[string]any {
	// ["integer","string"] for the reason the CRM's identical helper states: these doors take a
	// uuid or a bigint either way, and a schema that denies what the code accepts is drift.
	return map[string]any{"type": []string{"integer", "string"}, "description": desc}
}

func boolean(desc string) map[string]any {
	return map[string]any{"type": "boolean", "description": desc}
}

// key derives the ADR-005 claim for one call in one run: pkg/ids.CallKey's rules, not a second
// implementation, so this agent's keys and the memory tools' cannot drift. No run id means no
// key - an unattributed call must not share a constant uuid with every other unattributed call.
func key(ctx context.Context, toolName string, resolved []any) any {
	k := IdempotencyKey(turn.RunID(ctx), toolName, resolved)
	if k == "" {
		slog.Debug("this write is not claim-guarded: no run id in context", "tool", toolName)
		return nil
	}
	return k
}
