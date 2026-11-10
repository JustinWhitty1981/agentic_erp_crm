// Package orders is the sales and procurement agent's tool surface: reads over the vw_* views the
// orders programme published (ADR-003), and writes that are calls to the doors that raise, line,
// transition, fulfil and release a document (ADR-002). No file here composes an INSERT, and the
// reads compose WHERE clauses only against view columns - a state the views cannot express is a
// state this agent must not pretend to see.
//
// Twelve domain tools, wider than either deployed agent's surface, and that is the schema's shape
// rather than an ambition: a document has three doors here that finish it - ship, receive, release
// a commitment - because each answers a different question about the world, and one `complete_order`
// tool branching on order_type in Go would move the discrimination rule out of `order_lifecycle`
// and into a process, which is ADR-002's named failure. The fourth door the schema has,
// book_work_order_production, is deliberately not registered here; the requirements page says why.
package orders

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"jada-backend/pkg/tools"
	"jada-backend/pkg/turn"
)

// Querier is the whole of the database this package needs - the same two methods the other two
// agents' packages declare, for the same reason: a fake is cheap, and there is no Exec in the
// interface, so a write that is not a door cannot be composed here at all.
type Querier interface {
	// Query runs a SELECT and returns rows as generic values.
	Query(ctx context.Context, sql string, args ...any) ([]map[string]any, error)
	// Call invokes a stored function by name with positional arguments.
	Call(ctx context.Context, name string, args []any) ([]map[string]any, error)
}

// This process's name in the trail: agent_interactions.bot_id on every row it writes, conversational
// and scheduled alike - the field that separates this agent's trajectory from customer_service's and
// inventory's when three agents share one database, which is the case here.
const (
	EnvAgentRole     = "AGENT_ROLE"
	DefaultAgentRole = "sales"
)

// Row caps. The same reasoning as the CRM's and the inventory's: a model with a context window gets
// a bounded answer and a pointer to narrow it, never a truncation that looks like the whole truth.
const (
	defaultOrderRows = 20
	maxOrderRows     = 200
)

// Tools is the agent's orders surface: five reads over the views and seven doors.
//
// execute_inventory_movement is deliberately absent, and so is every item-master read. The first is
// the inventory agent's decision inherited verbatim - an agent that can move stock can silence the
// alarms its own documents raise. The second is a boundary worth stating out loud: this agent lines
// an order with `item_id` or with a description, and the ids come from the inventory agent's reads or
// from a human. Registering a shelf lookup here would be a second copy of a tool that already exists,
// and two copies is how one of them stops being true.
func Tools(q Querier) []tools.ToolDefinition {
	if q == nil {
		return nil
	}
	return []tools.ToolDefinition{
		getOrders(q),
		getOrderLines(q),
		getOrderCommitments(q),
		getCustomers(q),
		getSuppliers(q),
		createOrder(q),
		addOrderLine(q),
		transitionOrder(q),
		addSupplier(q),
		shipSalesOrder(q),
		receivePurchaseOrder(q),
		cancelReservation(q),
	}
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

func getOrders(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_orders",
		Description: "The documents: one row each, of any type, with its counterparty resolved and its totals" +
			"summed from its lines, plus three facts a list needs. lifecycle_position and is_terminal are" +
			"joined from the register, which is also a key the header cannot violate, so there is no such" +
			"thing here as a document holding a status its type never had. reports_a_movement is the" +
			"register's stock_moving: true for SHIPPED, RECEIVED and COMPLETED, the three statuses that" +
			"are consequences of stock rather than of decisions. open_amount is what is still to move," +
			"pro-rated line by line, in the header's currency - one currency per document is the rule," +
			"nothing is converted here, and 0018 is why. Narrow with order_type, status, open_only," +
			"customer_id, vendor_id, warehouse_id or due_before; a customer or supplier NAME belongs in" +
			"get_customers or get_suppliers, which is where an id comes from. origin=RESERVATION_BACKFILL" +
			"marks a document 0030 raised to explain stock that was already committed before any order" +
			"table existed; it carries no counterparty, and it is included by default because hiding it" +
			"would make this count disagree with the database's.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"order_type":   text("SALES, PURCHASE or WORK. Anything else is refused by the column."),
			"status":       text("One of the published statuses, as stored (DRAFT, SHIPPED...). See order_lifecycle's list by asking without it."),
			"open_only":    boolean("true to drop terminal documents - CLOSED and each type's cancelled/final state - from the answer."),
			"customer_id":  text("A customer's entity id (a bigint), from get_customers."),
			"vendor_id":    text("A supplier's uuid - not its entity id - from get_suppliers."),
			"warehouse_id": text("A warehouse uuid, to confine the list to one building."),
			"due_before":   text("An ISO date; answers 'what is overdue' together with open_only."),
			"limit":        integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultOrderRows, 1, maxOrderRows)
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
			if t := str(args, "order_type"); t != nil {
				T := strings.ToUpper(t.(string))
				if T != "SALES" && T != "PURCHASE" && T != "WORK" {
					return "", fmt.Errorf("order_type is SALES, PURCHASE or WORK, got %q", t)
				}
				add("order_type = ?", T)
			}
			if s := str(args, "status"); s != nil {
				add("status = ?", strings.ToUpper(s.(string)))
			}
			if boolArg(args, "open_only", false) == true {
				add("is_terminal IS NOT TRUE", nil)
			}
			if cid, err := id64(args, "customer_id"); err != nil {
				return "", err
			} else if cid != nil {
				add("customer_id = ?", cid)
			}
			vendorID, err := uuidArg(args, "vendor_id")
			if err != nil {
				return "", err
			}
			if vendorID != nil {
				add("vendor_id = ?", vendorID)
			}
			whID, err := uuidArg(args, "warehouse_id")
			if err != nil {
				return "", err
			}
			if whID != nil {
				add("warehouse_id = ?", whID)
			}
			if d, err := dateArg(args, "due_before"); err != nil {
				return "", err
			} else if d != nil {
				add("required_date <= ?::date", d)
			}

			// warehouse_id beside warehouse_name, in both of the lists that carry a warehouse.
			// The name is what a human says and the id is what a door takes; a read that returns one of
			// the two and not the other leaves the door unreachable, which is what stopped this agent
			// raising a purchase order at all. TestEveryDoorKeyIsReadableFromARead keeps them together.
			sql := "SELECT order_number, order_type, status, origin, lifecycle_position, is_terminal," +
				" reports_a_movement, customer_id, customer_name, vendor_id, vendor_code, vendor_name," +
				" warehouse_id, warehouse_name, currency_code, ordered_date, required_date, priority," +
				" line_count," +
				" total_amount, total_quantity, open_amount, status_reason, order_id" +
				" FROM vw_orders WHERE " + strings.Join(where, " AND ") +
				" ORDER BY required_date NULLS LAST, order_number DESC LIMIT $" +
				strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "no documents match - which is not the same as none existing"))
		},
	}
}

func getOrderLines(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_order_lines",
		Description: "What a document commits to, one row per line: quantity, unit, price, the generated amount," +
			"how much has fulfilled and cancelled, quantity_open, and line_state (OPEN, PARTIAL," +
			"FULFILLED, CANCELLED, UNFULFILLED_CLOSED) named from those numbers rather than stored in a" +
			"fourth column that could disagree with them. item_name is the item master's name and is null" +
			"on a line with no item; what such a line says about itself is description, which the schema" +
			"makes mandatory in item_id's place, so a one-off service is a real line and not an item" +
			"called MISCELLANEOUS. A null warehouse_id on a line means the document's own. Name the" +
			"document with order_id or order_number, or ask for one line by order_line_id. Without a" +
			"document this lists the newest lines of any order, which is a way to see activity and not a" +
			"way to audit one.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"order_id":         text("The document uuid."),
			"order_number":     text("SO-/PO-/WO- number, exact, as a human would read it aloud."),
			"order_line_id":    text("One line, by uuid, when a single line is the question."),
			"line_type":        text("STANDARD, COMPONENT or PRODUCT - what the line does to stock."),
			"unfulfilled_only": boolean("true to drop lines with nothing left to move."),
			"limit":            integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultOrderRows, 1, maxOrderRows)
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
			oid, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			if oid != nil {
				add("order_id = ?", oid)
			}
			if n := str(args, "order_number"); n != nil {
				add("order_number = ?", strings.ToUpper(strings.TrimSpace(n.(string))))
			}
			lid, err := uuidArg(args, "order_line_id")
			if err != nil {
				return "", err
			}
			if lid != nil {
				add("order_line_id = ?", lid)
			}
			if lt := str(args, "line_type"); lt != nil {
				L := strings.ToUpper(lt.(string))
				if L != "STANDARD" && L != "COMPONENT" && L != "PRODUCT" {
					return "", fmt.Errorf("line_type is STANDARD, COMPONENT or PRODUCT, got %q", lt)
				}
				add("line_type = ?", L)
			}
			if boolArg(args, "unfulfilled_only", false) == true {
				add("quantity_open > 0", nil)
			}

			sql := "SELECT order_number, order_type, order_status, line_number, line_type, item_id," +
				" sku, item_name, item_product_type, description, quantity, unit_of_measure," +
				" unit_price, line_amount, quantity_fulfilled, quantity_cancelled, quantity_open," +
				" line_state, warehouse_id, warehouse_code, lot_number, required_date, order_id," +
				" order_line_id" +
				" FROM vw_order_lines WHERE " + strings.Join(where, " AND ") +
				" ORDER BY order_number DESC, line_number LIMIT $" + strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "that document has no lines - nothing is committed, ordered or owed"))
		},
	}
}

func getOrderCommitments(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_order_commitments",
		Description: "The reconciliation, one row per line: what the line promises, how many units are held" +
			"against it (quantity_committed, attributed by line), how many of those have settled" +
			"(quantity_released), how many are still unresolved, and quantity_committed_unlinked - held" +
			"for this document and item but naming NO line, counted separately on purpose because the" +
			"join that attributes a commitment cannot see it, and nothing held beside held-but-not-" +
			"attributed is the pair of numbers in this domain that could be acted on wrongly. ledger_rows" +
			"and ledger_quantity say what actually moved, with RESERVATION rows excluded, because a" +
			"commitment makes stock unavailable and moves nothing; ledger_agreement is the verdict:" +
			"nothing moved yet, fulfilled without a movement (non-stock line), agrees, or DISAGREES. Ask" +
			"with only_disagreements for the alarm and only_held for what is promised and sitting. A" +
			"service line is never a disagreement: it is fulfilled by the document, with no movement to" +
			"compare against.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"order_id":           text("Confine to one document."),
			"order_number":       text("Or name it the way a human does."),
			"only_disagreements": boolean("true for rows whose counter and ledger do not agree - the check the hourly tick runs, asked by hand."),
			"only_held":          boolean("true for rows with unresolved units held against them."),
			"limit":              integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultOrderRows, 1, maxOrderRows)
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
			oid, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			if oid != nil {
				add("order_id = ?", oid)
			}
			if n := str(args, "order_number"); n != nil {
				add("order_number = ?", strings.ToUpper(strings.TrimSpace(n.(string))))
			}
			if boolArg(args, "only_disagreements", false) == true {
				add("ledger_agreement = 'DISAGREES'", nil)
			}
			if boolArg(args, "only_held", false) == true {
				add("quantity_unresolved > 0", nil)
			}

			sql := "SELECT order_number, order_type, order_status, line_number, line_type, item_id," +
				" item_name, quantity, quantity_open, quantity_committed, quantity_released," +
				" quantity_unresolved, quantity_committed_unlinked, ledger_rows, ledger_quantity," +
				" ledger_agreement, required_date, order_id, order_line_id" +
				" FROM vw_order_commitments WHERE " + strings.Join(where, " AND ") +
				" ORDER BY quantity_unresolved DESC, order_number, line_number LIMIT $" +
				strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			note := "no line of this document has stock held against it"
			if boolArg(args, "only_disagreements", false) == true {
				note = "every line's counter agrees with the ledger that moved it"
			}
			return Rows(withNote(rows, note))
		},
	}
}

func getCustomers(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_customers",
		Description: "The party an order is FOR: id, name, status, email and phone, from the customer " +
			"view. This exists to turn a name into the entity id create_order needs - a customer's " +
			"history is the service agent's surface and is not here. Name is a case-insensitive " +
			"substring, so two rows coming back is a decision about which company was meant and not a " +
			"tie to break silently; pass the id, never a guess at one.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"name":        text("Substring of the party's name, as stored."),
			"customer_id": text("Or resolve the other way: an id you already hold, to confirm it exists."),
			"limit":       integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultOrderRows, 1, maxOrderRows)
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
			if n := str(args, "name"); n != nil {
				add("name ILIKE ?", "%"+escapeLike(n.(string))+"%")
			}
			cid, err := id64(args, "customer_id")
			if err != nil {
				return "", err
			}
			if cid != nil {
				add("id = ?", cid)
			}

			sql := "SELECT id AS customer_id, name, email, phone, status FROM vw_customers WHERE " +
				strings.Join(where, " AND ") + " ORDER BY name LIMIT $" + strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "no party matched that name - add_customer is the service agent's tool, not this one"))
		},
	}
}

func getSuppliers(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_suppliers",
		Description: "Who we buy from, and on what terms: the supplier code, the party behind it (name, tax id," +
			"and that party's own entity_type value - read party_type rather than inferring a role from" +
			"anything, because one CHECK holds one value per row and that is exactly the limit 0027" +
			"worked around), payment_terms, lead_time_days, and the currency their invoices come in. Two" +
			"ids per row and the difference matters: supplier_id is what create_order's vendor_id takes," +
			"because orders.vendor_id is a key into suppliers and not into entities; entity_id is the" +
			"party, which is what add_supplier attaches to and what the service agent would use. Ask by" +
			"name or code. include_inactive defaults to leaving retired suppliers out, because a retired" +
			"supplier is a decision somebody made.",
		Policy: tools.ToolPolicy{ReadOnly: true},
		Parameters: object(map[string]any{
			"name":             text("Substring of the supplier's party name."),
			"supplier_code":    text("Exact code, as stored - what a line's SUPPLIER:<code> reference names."),
			"include_inactive": boolean("true to include suppliers marked retired."),
			"limit":            integer("Rows to return, 1-200. Default 20."),
		}),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultOrderRows, 1, maxOrderRows)
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
			if n := str(args, "name"); n != nil {
				add("party_name ILIKE ?", "%"+escapeLike(n.(string))+"%")
			}
			if c := str(args, "supplier_code"); c != nil {
				add("supplier_code = ?", strings.ToUpper(strings.TrimSpace(c.(string))))
			}
			if boolArg(args, "include_inactive", false) != true {
				add("is_active", nil)
			}

			sql := "SELECT supplier_id, supplier_code, entity_id, party_name, legal_name, tax_id," +
				" party_type, payment_terms, lead_time_days, currency_code, is_active FROM vw_suppliers WHERE " +
				strings.Join(where, " AND ") + " ORDER BY supplier_code LIMIT $" + strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "no supplier matches - create one with add_supplier before a purchase order can name it"))
		},
	}
}

// ---------------------------------------------------------------------------
// Writes: every one of them a door, and every one of them claiming a key (ADR-005)
// ---------------------------------------------------------------------------

func createOrder(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "create_order",
		Description: "Raise a document: SALES for a customer, PURCHASE to a supplier, WORK to make something. It" +
			"answers with the order_id and the human-readable order_number, and the number is issued from" +
			"a per-type counter here, so no caller composes one; two tenants each holding a PO-000001 is" +
			"not a collision in this schema and would be in a tool that built the string. Exactly one" +
			"counterparty, as orders_counterparty_matches_type demands: customer_id for SALES, vendor_id" +
			"for PURCHASE (a supplier_id from get_suppliers, not its entity_id), neither for WORK. A" +
			"purchase order with no vendor is refused rather than raised to be fixed later, because a" +
			"document that cannot say who it was placed with is not a purchase order. It always starts at" +
			"DRAFT: there is no argument that creates one further along, because a status is a position" +
			"in a lifecycle and every lifecycle begins at DRAFT. Lines come next, with add_order_line -" +
			"an order with no lines is a promise with nothing in it.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"order_type":  text("SALES, PURCHASE or WORK. Required."),
				"customer_id": text("The buying party's entity id, for SALES. From get_customers."),
				"vendor_id":   text("The supplier's supplier_id, for PURCHASE. From get_suppliers."),
				"warehouse_id": text("The document's warehouse, as a uuid; lines may override it. Optional, " +
					"and worth giving, because the fulfilment doors receive into or issue out of THIS row " +
					"when a line names none. A code is not accepted - MAIN is a name and the edge is keyed " +
					"to the identity - and the only place this process can read the pair is get_orders, " +
					"whose rows carry warehouse_id beside warehouse_name. There is no warehouse list here: " +
					"on a database with no documents yet, ask the inventory agent."),
				"required_date": text("ISO date the document is needed by; what the release order drains on. Omit for no promise."),
				"priority":      integer("1 highest to 4 lowest. Omit for the schema's default."),
				"currency_code": text("ISO-4217 three-letter code every line price on this document will " +
					"be in. Omit it and the door writes USD, which is the column's own default and not " +
					"inherited from anybody: entities has no currency column to inherit from, and a " +
					"relationship attribute invented for the sake of a default would be a second place to " +
					"say the same thing. One currency per document, and nothing converts it (0018)."),
				"notes": text("Why this document exists, in the words whoever asked would use."),
			})
			p["required"] = []string{"order_type"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			orderType := str(args, "order_type")
			if orderType == nil {
				return "", fmt.Errorf("order_type is required: SALES, PURCHASE or WORK")
			}
			orderType = strings.ToUpper(orderType.(string))
			if orderType != "SALES" && orderType != "PURCHASE" && orderType != "WORK" {
				return "", fmt.Errorf("order_type is SALES, PURCHASE or WORK, got %v", args["order_type"])
			}
			customerID, err := id64(args, "customer_id")
			if err != nil {
				return "", err
			}
			vendorID, err := uuidArg(args, "vendor_id")
			if err != nil {
				return "", err
			}
			whID, err := uuidArg(args, "warehouse_id")
			if err != nil {
				return "", err
			}
			reqDate, err := dateArg(args, "required_date")
			if err != nil {
				return "", err
			}
			prio, err := days(args, "priority", 0)
			if err != nil {
				return "", err
			}
			var prioArg any
			if prio != 0 {
				prioArg = int64(prio)
			}
			// Nine door parameters before the claim, in the order the door declares them, and origin is
			// this agent saying what it is: every document raised here is a human's decision, so MANUAL,
			// and the one value that would sit in that slot otherwise is the key - which is the failure
			// TestEveryDoorSendsItsFullArityAndTheClaimLast exists to make impossible.
			resolved := []any{orderType, customerID, vendorID, whID,
				str(args, "currency_code"), reqDate, prioArg, str(args, "notes"), "MANUAL"}

			rows, err := q.Call(ctx, "create_order", append(resolved, key(ctx, "create_order", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "create_order", func(r map[string]any) {
				turn.Source(ctx, "orders", r["order_id"])
				slog.Info("order raised", "order_type", orderType, "order_number", r["order_number"],
					"order_id", r["order_id"])
			})
		},
	}
}

func addOrderLine(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "add_order_line",
		Description: "Add one line to a document: a quantity at a price, either of an item (item_id) or with no" +
			"item and a description, which is a real line rather than a placeholder - 0028 made item_id" +
			"nullable so a purchase order can procure the plumber without filing him in the item master." +
			"The line number is the document's next position, allocated by the door under its own unique" +
			"index, and an identical retry is one line and not two because of the claim. unit_of_measure" +
			"defaults to the item master's base unit; passing one is allowed and is what gets stored, so" +
			"pass it only when the line is genuinely counted differently (a case of something sold" +
			"individually) and leave it alone otherwise. warehouse_id overrides the document's for this" +
			"line alone. It refuses a document already in a terminal state, which takes no new lines, and" +
			"a line_type the document kind cannot hold: COMPONENT and PRODUCT are a work order's" +
			"vocabulary for what it consumes and what it yields, and on a sales or purchase line STANDARD" +
			"is the answer.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"order_id": text("The document to add to. Required."),
				"item_id": text("The inventory_items uuid, for a line that IS a catalog item. This agent " +
					"has no item master - deliberately, because the inventory agent's reads are the shelf - " +
					"so the ids reachable from here are the ones on documents that already exist: " +
					"get_order_lines carries item_id beside sku and item_name. An SKU you have never " +
					"ordered has no id this surface can produce, and the answer is a description and no " +
					"item, which is a supported shape rather than a fallback: 0028 made item_id nullable " +
					"so a purchase order can procure the plumber."),
				"description": text("What the line is. Required when item_id is absent."),
				"quantity":    number("How many, in unit_of_measure. Positive. Required."),
				"unit_price":  number("Price per unit, in the order's currency. Required."),
				"unit_of_measure": text("Defaults to the item master's base unit. Passing one is allowed and " +
					"is what gets stored - the door coalesces rather than comparing - so pass it only when " +
					"the line is genuinely counted differently, a case of something the master counts " +
					"individually. Leaving it absent is the right answer most of the time."),
				"line_type":     text("STANDARD (the default), COMPONENT or PRODUCT."),
				"warehouse_id":  text("This line's warehouse, when the document's own is not the right one."),
				"required_date": text("ISO date, for this line only."),
				"lot_number":    text("When a particular lot is wanted. Empty means any, and the pick drains FEFO."),
				"notes":         text("Anything true about this line that the numbers do not say."),
			})
			p["required"] = []string{"order_id", "quantity", "unit_price"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			orderID, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			if orderID == nil {
				return "", fmt.Errorf("order_id is required - a line belongs to a document")
			}
			itemID, err := uuidArg(args, "item_id")
			if err != nil {
				return "", err
			}
			desc := str(args, "description")
			if itemID == nil && desc == nil {
				return "", fmt.Errorf("a line names an item or says what it is: pass item_id or description")
			}
			qty, err := numericArg(args, "quantity")
			if err != nil {
				return "", err
			}
			price, err := numericArg(args, "unit_price")
			if err != nil {
				return "", err
			}
			lineType := strDefault(args, "line_type", "STANDARD")
			if s, ok := lineType.(string); ok {
				lineType = strings.ToUpper(s)
			}
			whID, err := uuidArg(args, "warehouse_id")
			if err != nil {
				return "", err
			}
			reqDate, err := dateArg(args, "required_date")
			if err != nil {
				return "", err
			}
			resolved := []any{orderID, itemID, desc, qty, price,
				str(args, "unit_of_measure"), lineType, whID, reqDate,
				str(args, "lot_number"), str(args, "notes")}

			rows, err := q.Call(ctx, "add_order_line", append(resolved, key(ctx, "add_order_line", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "add_order_line", func(r map[string]any) {
				turn.Source(ctx, "order_items", r["order_line_id"])
				slog.Info("order line added", "order_id", orderID, "line_number", r["line_number"],
					"order_line_id", r["order_line_id"])
			})
		},
	}
}

func transitionOrder(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "transition_order",
		Description: "Move a document to its next status, and refuse everything else. What is legal is the" +
			"register's, not this tool's: SALES runs DRAFT, CONFIRMED, PICKING, SHIPPED; PURCHASE runs" +
			"DRAFT, SUBMITTED, RECEIVED; WORK runs DRAFT, RELEASED, IN_PRODUCTION, COMPLETED - each with" +
			"CLOSED and CANCELLED as ways to stop. The move must be forward, and a status the register" +
			"marks stock_moving - SHIPPED, RECEIVED, COMPLETED - is refused here and belongs to the door" +
			"that moves the stock, which is the whole design of this tool: an order cannot be made" +
			"shipped by typing, because the ledger would then disagree with the document, and that is the" +
			"failure this schema has been built to make impossible. SUBMITTED on a SALES order is refused" +
			"for a different reason, and the message says which: that type never had that status." +
			"expected_version from get_orders says nothing else changed it in between; it is checked" +
			"before the direction rules, so a caller working from a stale read is told that rather than" +
			"being told its move was backwards. CANCELLED is exempt from the forward-only rule, because" +
			"turning an agreement off is not a step backwards in it. reason is asked for and kept," +
			"because a status change nobody can explain later is a rumour.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"order_id":         text("The document. Required."),
				"to_status":        text("DRAFT, SUBMITTED, CONFIRMED, PICKING, RELEASED, IN_PRODUCTION, PACKED, CLOSED or CANCELLED - which of them are legal depends on the type and where it is now. Required."),
				"reason":           text("Why, in a sentence."),
				"expected_version": integer("The version the read showed. Omit to skip the guard, which is allowed and weaker."),
			})
			p["required"] = []string{"order_id", "to_status"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			orderID, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			if orderID == nil {
				return "", fmt.Errorf("order_id is required - name the document whose status changes")
			}
			status := str(args, "to_status")
			if status == nil {
				return "", fmt.Errorf("to_status is required")
			}
			status = strings.ToUpper(status.(string))
			ver, err := days(args, "expected_version", -1)
			if err != nil {
				return "", err
			}
			var verArg any
			if ver >= 0 {
				verArg = int64(ver)
			}
			resolved := []any{orderID, status, str(args, "reason"), verArg}

			rows, err := q.Call(ctx, "transition_order", append(resolved, key(ctx, "transition_order", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "transition_order", func(r map[string]any) {
				turn.Source(ctx, "orders", r["order_id"])
				slog.Info("order transitioned", "order_id", orderID, "to_status", status)
			})
		},
	}
}

func addSupplier(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "add_supplier",
		Description: "Say that a party is one of ours to buy from, which in this schema is the existence of a row" +
			"rather than the value of a column: the party keeps being an entity and can still be a" +
			"customer, because entities.entity_type holds one value per row and that is the limit 0027" +
			"worked around rather than inherited. Give either entity_id (an existing party - a customer" +
			"who also sells to us, and get_customers finds the id) or name (make the party and the" +
			"supplier in one call), and not both, which the door answers as a wrong argument." +
			"supplier_code is upper-cased and unique per tenant, so a code already in use arrives as the" +
			"constraint's own duplicate key and a party that is already a supplier says one party, one" +
			"supplier record. payment_terms is free text on purpose: it belongs to the agreement, not to" +
			"a vocabulary nothing could enforce it against. lead_time_days is the number a replenishment" +
			"decision reads; leaving it out says nobody has measured it, which is a different sentence" +
			"from zero.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"supplier_code":  text("The tenant-unique code. Required."),
				"entity_id":      text("An existing party's entity id, when they are already in the book."),
				"name":           text("The trading name, when there is no party yet."),
				"tax_id":         text("Tax reference."),
				"payment_terms":  text("NET30, COD, 'on receipt' - free text, as stored."),
				"lead_time_days": integer("How long an order to them normally takes; the number a replenishment decision reads."),
				"currency_code":  text("ISO-4217, for what their invoices are in."),
				"notes":          text("Anything worth knowing about how they work."),
			})
			p["required"] = []string{"supplier_code"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			code := str(args, "supplier_code")
			if code == nil {
				return "", fmt.Errorf("supplier_code is required - it is what a purchase line's SUPPLIER: reference resolves by")
			}
			entityID, err := id64(args, "entity_id")
			if err != nil {
				return "", err
			}
			lead, err := days(args, "lead_time_days", 0)
			if err != nil {
				return "", err
			}
			var leadArg any
			if lead != 0 {
				leadArg = int64(lead)
			}
			resolved := []any{code, entityID, str(args, "name"), str(args, "tax_id"),
				str(args, "payment_terms"), leadArg, str(args, "currency_code"),
				str(args, "notes"), true}

			rows, err := q.Call(ctx, "add_supplier", append(resolved, key(ctx, "add_supplier", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "add_supplier", func(r map[string]any) {
				turn.Source(ctx, "suppliers", r["supplier_id"])
				slog.Info("supplier registered", "supplier_code", code, "supplier_id", r["supplier_id"])
			})
		},
	}
}

func shipSalesOrder(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "ship_sales_order",
		Description: "Ship what a sales order still owes. For every open STANDARD line it settles whatever" +
			"commitment the document holds for that item, issues the stock out of the line's or the" +
			"document's warehouse naming the line, and raises the line's counter in the same statement," +
			"so the reconciliation view agrees with itself afterwards. The status is computed rather than" +
			"asserted - SHIPPED when nothing is left open, PICKING while something is - so a partial" +
			"shipment cannot report itself complete. There is no per-line variant on purpose: a shipment" +
			"is a document event, and what is off the agreement entirely is quantity_cancelled on the" +
			"line, which this door does not guess. It refuses a document that is not SALES or is already" +
			"terminal, refuses a line with no item (a sales order ships goods; a service is fulfilled by" +
			"closing the document), and refuses when nothing is open. When the bins cannot supply, the" +
			"ledger refuses and says how much was available across how many bins: reserve it or restock," +
			"and do not retry a precise answer unchanged. warehouse_id overrides the document's own when" +
			"the stock leaves from somewhere else.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"order_id":     text("The sales order. Required."),
				"warehouse_id": text("Where it leaves from, if not the document's."),
				"performed_by": text("Who is doing it; defaults to this agent's name, which is why a human should say."),
			})
			p["required"] = []string{"order_id"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			orderID, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			if orderID == nil {
				return "", fmt.Errorf("order_id is required - nothing ships without a document")
			}
			whID, err := uuidArg(args, "warehouse_id")
			if err != nil {
				return "", err
			}
			by := strDefault(args, "performed_by", AgentName())
			resolved := []any{orderID, whID, by}

			rows, err := q.Call(ctx, "ship_sales_order", append(resolved, key(ctx, "ship_sales_order", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "ship_sales_order", func(r map[string]any) {
				turn.Source(ctx, "orders", r["order_id"])
				slog.Info("sales order shipped", "order_number", r["order_number"],
					"shipped_quantity", r["shipped_quantity"])
			})
		},
	}
}

func receivePurchaseOrder(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "receive_purchase_order",
		Description: "Book what arrived against a purchase order: every open STANDARD line is received into the" +
			"document's warehouse, or the one named here, with a movement row naming the line and its" +
			"counter raised with it. A line with no item, or an item the master calls a SERVICE, is" +
			"fulfilled without a movement - paying a hired engineer is what a delivered service means," +
			"and putting a phantom unit in a bin to make a counter go up is the other way to be wrong." +
			"The status is computed: RECEIVED when nothing is owed, SUBMITTED while something still is," +
			"so a partial delivery does not report itself complete. Whether the rest is coming is a" +
			"decision about the supplier, not a consequence of a pallet. It refuses a document that is" +
			"not a non-terminal PURCHASE order, refuses one that names no warehouse to receive into, and" +
			"refuses when nothing is outstanding. Like shipping, it is a document event and not a line" +
			"event, because a delivery note says what came off the truck against the order.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"order_id":     text("The purchase order. Required."),
				"warehouse_id": text("Where it arrives, if not the document's."),
				"performed_by": text("Who received it; defaults to this agent's name."),
			})
			p["required"] = []string{"order_id"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			orderID, err := uuidArg(args, "order_id")
			if err != nil {
				return "", err
			}
			if orderID == nil {
				return "", fmt.Errorf("order_id is required - a receipt without a document is an adjustment")
			}
			whID, err := uuidArg(args, "warehouse_id")
			if err != nil {
				return "", err
			}
			by := strDefault(args, "performed_by", AgentName())
			resolved := []any{orderID, whID, by}

			rows, err := q.Call(ctx, "receive_purchase_order", append(resolved, key(ctx, "receive_purchase_order", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "receive_purchase_order", func(r map[string]any) {
				turn.Source(ctx, "orders", r["order_id"])
				slog.Info("purchase order received", "order_number", r["order_number"],
					"received_quantity", r["received_quantity"])
			})
		},
	}
}

func cancelReservation(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "cancel_inventory_reservation",
		Description: "Release stock that is being held for a document - the door that did not exist until 0030," +
			"which is why thirteen units on this server had been committed forever. reservation_id is" +
			"what the inventory agent's reserve tool answers with, and get_order_commitments names the" +
			"lines and quantities a human is pointing at. quantity releases part of a commitment;" +
			"omitting it releases everything still open, and more than that is refused rather than" +
			"rounded down. A quantity of zero or less is an argument error, not a no-op. The reservation" +
			"row stays: a commitment is a fact with a history, and 0008's rule for a thing that cannot" +
			"leave a trail is that it does not get deleted. What it refuses, in its own words: a" +
			"reservation this connection cannot see, which by 0009's wall is also what a wrong id looks" +
			"like; one that is already settled, every unit shipped or cancelled, where releasing it again" +
			"would take stock the document never promised; and a release larger than what is open, where" +
			"the hint says shipped units are consumed by the ship door and not cancelled here. This does" +
			"not cancel the ORDER: whether the agreement is off is transition_order's decision.",
		Policy: tools.ToolPolicy{ReadOnly: false, Claims: true},
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"reservation_id": text("The commitment to release. Required."),
				"quantity":       number("How much to release; omit for everything still held."),
				"reason":         text("Why it is being let go - kept on the row and in the trail."),
				"cancelled_by":   text("Who asked; defaults to this agent's name."),
			})
			p["required"] = []string{"reservation_id"}
			return p
		}(),
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			rid, err := uuidArg(args, "reservation_id")
			if err != nil {
				return "", err
			}
			if rid == nil {
				return "", fmt.Errorf("reservation_id is required - get_order_commitments and reserve_inventory both answer with it")
			}
			qty, err := numericArg(args, "quantity")
			if err != nil {
				return "", err
			}
			by := strDefault(args, "cancelled_by", AgentName())
			resolved := []any{rid, qty, str(args, "reason"), by}

			rows, err := q.Call(ctx, "cancel_inventory_reservation",
				append(resolved, key(ctx, "cancel_inventory_reservation", resolved)))
			if err != nil {
				return "", err
			}
			return doorRow(ctx, rows, "cancel_inventory_reservation",
				func(r map[string]any) {
					turn.Source(ctx, "inventory_reservations", r["reservation_id"])
					slog.Info("reservation released", "reservation_id", rid,
						"released_quantity", r["released_quantity"], "status", r["status"])
				})
		},
	}
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

// domainToolNames is this agent's own surface, as opposed to the six shared tools every fork
// carries (current_time, the two web tools, the three memory ones).
var domainToolNames = []string{
	"get_orders", "get_order_lines", "get_order_commitments", "get_customers", "get_suppliers",
	"create_order", "add_order_line", "transition_order", "add_supplier", "ship_sales_order",
	"receive_purchase_order", "cancel_inventory_reservation",
}

// IsDomainTool says whether a registered name belongs to the orders surface.
//
// It exists because /api/health reports how many domain tools came up, and the sibling forks count
// that with a list of name *prefixes* written where nobody could check them against the registry: an
// earlier draft of this file used the same trick and left get_customers out, so a healthy process
// with all twelve registered answered eleven. One predicate, asserted against Tools() by
// TestDomainToolNamesMatchTheRegistry, is the difference between a health number that means the
// registration and one that means somebody's typing.
func IsDomainTool(name string) bool {
	for _, n := range domainToolNames {
		if n == name {
			return true
		}
	}
	return false
}

// AgentName is what this process calls itself in the trail, resolved once per call from the
// environment the deployment set.
func AgentName() string {
	if v := strings.TrimSpace(os.Getenv(EnvAgentRole)); v != "" {
		return v
	}
	return DefaultAgentRole
}

// doorRow is the shape all eight writes share: the door answers one row, success or not, and the
// verdict - not the prose - is what decides whether the turn's sources get recorded. A refusal is a
// result: it is returned as data so the model can read the reason the database gave, and only a
// missing row is an error, because a door that answers nothing did not run.
func doorRow(ctx context.Context, rows []map[string]any, door string, note func(map[string]any)) (string, error) {
	if len(rows) == 0 {
		return "", fmt.Errorf("%s returned no row: the operation did not happen", door)
	}
	row := rows[0]
	if ok, _ := row["success"].(bool); ok && note != nil {
		note(row)
	} else if !ok {
		slog.Info("door refused", "door", door, "message", row["message"])
	}
	return mustJSON(row)
}

// uuidArg reads a uuid-shaped string argument, nil when absent: the same rule the other two agents
// apply, validated here so a malformed id is a tool-level error naming its own argument rather than
// a 22P02 from inside a function the model cannot see. Whether the id EXISTS is the database's fact,
// and the door answers that one.
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

// dateArg is an ISO date, checked for the two shapes the doors accept and nothing else: a date that
// PostgreSQL would have to guess the meaning of is a tool error, not an INSERT that reorders it.
func dateArg(args map[string]any, name string) (any, error) {
	v := str(args, name)
	if v == nil {
		return nil, nil
	}
	s := strings.TrimSpace(v.(string))
	for _, layout := range []string{"2006-01-02", time.RFC3339} {
		if _, err := time.Parse(layout, s); err == nil {
			return s, nil
		}
	}
	return nil, fmt.Errorf("%s is not an ISO date: %q", name, v)
}

// numericArg accepts the JSON number or the string a model may send for a numeric door parameter,
// and refuses the third thing: a value the decoder already lost. Money and quantities are the two
// places in this domain where a silent float rounding is a wrong order line.
func numericArg(args map[string]any, name string) (any, error) {
	switch v := args[name].(type) {
	case nil:
		return nil, nil
	case float64:
		// Shortest round-trip decimal, so 12.5 never arrives as 12.500000000000001 and the door's
		// numeric(18,4) sees the number the caller meant rather than one the decoder chose.
		return strconv.FormatFloat(v, 'f', -1, 64), nil
	case string:
		s := strings.TrimSpace(v)
		if s == "" {
			return nil, nil
		}
		if _, err := strconv.ParseFloat(s, 64); err != nil {
			return nil, fmt.Errorf("%s is not a number: %q", name, v)
		}
		return s, nil
	default:
		return nil, fmt.Errorf("%s must be a number, got %T", name, v)
	}
}

// escapeLike protects the ILIKE patterns from a caller who types a percent.
func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

func object(props map[string]any) map[string]any {
	return map[string]any{"type": "object", "properties": props}
}

func text(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }

func integer(desc string) map[string]any {
	return map[string]any{"type": []string{"integer", "string"}, "description": desc}
}

func number(desc string) map[string]any {
	return map[string]any{"type": []string{"number", "string"}, "description": desc}
}

func boolean(desc string) map[string]any {
	return map[string]any{"type": "boolean", "description": desc}
}

// key derives the ADR-005 claim for one call in one run: pkg/ids.CallKey's rules, not a second
// implementation, so this agent's keys and the memory tools' cannot drift. No run id means no key -
// an unattributed call must not share a constant uuid with every other unattributed call, and the nil
// this returns for that case reaches the door's p_idempotency_key as SQL NULL, which every one of
// these doors reads as "run unguarded" rather than as an id.
//
// It is one value appended after the door's own arguments, and it is LAST in all eight calls: a claim
// key landing in a column is a reservation whose idempotency is a warehouse, so TestClaimsAreLast
// asserts the position rather than trusting the reading of a signature.
func key(ctx context.Context, toolName string, resolved []any) any {
	k := IdempotencyKey(turn.RunID(ctx), toolName, resolved)
	if k == "" {
		slog.Debug("this write is not claim-guarded: no run id in context", "tool", toolName)
		return nil
	}
	return k
}
