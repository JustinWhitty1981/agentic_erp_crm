-- Customer Management Functions
-- Provides safe add and update operations for customers with validation

-- Drop existing functions if they exist (to avoid conflicts)
DROP FUNCTION IF EXISTS add_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS update_customer;
DROP FUNCTION IF EXISTS get_followup_customers(INTEGER);

-- Function: Add a new customer
-- Creates entity, contact, address, and relationship records atomically
CREATE OR REPLACE FUNCTION add_customer(
    p_first_name TEXT,
    p_last_name TEXT,
    p_email TEXT,
    p_phone TEXT,
    p_street TEXT DEFAULT NULL,
    p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL,
    p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT 'US',
    p_status TEXT DEFAULT 'active'
) RETURNS TABLE(
    success BOOLEAN,
    entity_id INTEGER,
    contact_id INTEGER,
    message TEXT
) AS $$
DECLARE
    v_entity_id INTEGER;
    v_contact_id INTEGER;
    v_existing_count INTEGER;
BEGIN
    -- Validation: Require first and last name
    IF p_first_name IS NULL OR p_first_name = '' THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 'First name is required';
        RETURN;
    END IF;
    
    IF p_last_name IS NULL OR p_last_name = '' THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 'Last name is required';
        RETURN;
    END IF;
    
    -- Validation: Require at least one of email or phone
    IF (p_email IS NULL OR p_email = '') AND (p_phone IS NULL OR p_phone = '') THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 'At least one of email or phone is required';
        RETURN;
    END IF;
    
    -- Check for duplicate email
    IF p_email IS NOT NULL AND p_email != '' THEN
        SELECT COUNT(*) INTO v_existing_count 
        FROM agent_swarm.contacts 
        WHERE email ILIKE p_email;
        
        IF v_existing_count > 0 THEN
            RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 
                'A contact with this email already exists';
            RETURN;
        END IF;
    END IF;
    
    -- Check for duplicate phone
    IF p_phone IS NOT NULL AND p_phone != '' THEN
        SELECT COUNT(*) INTO v_existing_count 
        FROM agent_swarm.contacts 
        WHERE phone = p_phone;
        
        IF v_existing_count > 0 THEN
            RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 
                'A contact with this phone number already exists';
            RETURN;
        END IF;
    END IF;
    
    -- Create the entity
    INSERT INTO agent_swarm.entities (entity_type, name, status, created_at, updated_at)
    VALUES ('customer', trim(p_first_name || ' ' || p_last_name), p_status, NOW(), NOW())
    RETURNING id INTO v_entity_id;
    
    -- Create the contact
    INSERT INTO agent_swarm.contacts (first_name, last_name, email, phone, status, created_at, updated_at)
    VALUES (p_first_name, p_last_name, p_email, p_phone, 'active', NOW(), NOW())
    RETURNING id INTO v_contact_id;
    
    -- Create the entity relationship (primary)
    INSERT INTO agent_swarm.entity_relationships (entity_id, contact_id, role, is_primary, created_at)
    VALUES (v_entity_id, v_contact_id, 'Customer', TRUE, NOW());
    
    -- Create address if provided
    IF p_street IS NOT NULL OR p_city IS NOT NULL OR p_state IS NOT NULL OR p_postal_code IS NOT NULL THEN
        INSERT INTO agent_swarm.addresses (
            entity_id, contact_id, address_type, 
            street, city, state, postal_code, country, is_primary, created_at
        ) VALUES (
            v_entity_id, v_contact_id, 'home',
            p_street, p_city, p_state, p_postal_code, p_country, TRUE, NOW()
        );
    END IF;
    
    -- Return success
    RETURN QUERY SELECT TRUE, v_entity_id, v_contact_id, 
        'Customer added successfully: ' || p_first_name || ' ' || p_last_name;
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 
            'Error adding customer: ' || SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Function: Update a customer's information
-- Updates contact, address, and entity records atomically
-- FIXED: Resolved ambiguous column reference errors by using explicit table aliases
CREATE OR REPLACE FUNCTION update_customer(
    p_search_name TEXT,
    p_search_email TEXT DEFAULT NULL,
    p_search_phone TEXT DEFAULT NULL,
    p_first_name TEXT DEFAULT NULL,
    p_last_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_street TEXT DEFAULT NULL,
    p_city TEXT DEFAULT NULL,
    p_state TEXT DEFAULT NULL,
    p_postal_code TEXT DEFAULT NULL,
    p_country TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL
) RETURNS TABLE(
    success BOOLEAN,
    entity_id INTEGER,
    contact_id INTEGER,
    message TEXT
) AS $$
DECLARE
    v_entity_id INTEGER;
    v_contact_id INTEGER;
    v_existing_count INTEGER;
    v_old_data JSONB;
BEGIN
    -- Find the customer by name (and optionally email/phone for more precision)
    SELECT e.id, c.id 
    INTO v_entity_id, v_contact_id
    FROM agent_swarm.entities e
    JOIN agent_swarm.entity_relationships er ON e.id = er.entity_id AND er.is_primary = TRUE
    JOIN agent_swarm.contacts c ON er.contact_id = c.id
    WHERE e.name ILIKE '%' || p_search_name || '%'
    AND (p_search_email IS NULL OR c.email ILIKE p_search_email)
    AND (p_search_phone IS NULL OR c.phone = p_search_phone)
    LIMIT 1;
    
    -- Check if customer exists
    IF v_entity_id IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 
            'Customer not found: ' || p_search_name;
        RETURN;
    END IF;
    
    -- Get old data for audit (stored in variable; audit_log table doesn't exist so we skip writing it)
    SELECT jsonb_build_object(
        'entity_name', ent.name,
        'first_name', cont.first_name,
        'last_name', cont.last_name,
        'email', cont.email,
        'phone', cont.phone,
        'status', ent.status
    ) INTO v_old_data
    FROM agent_swarm.entities ent
    JOIN agent_swarm.entity_relationships er ON ent.id = er.entity_id AND er.is_primary = TRUE
    JOIN agent_swarm.contacts cont ON er.contact_id = cont.id
    WHERE ent.id = v_entity_id;
    
    -- Check for email conflict if updating email
    IF p_email IS NOT NULL AND p_email != '' THEN
        SELECT COUNT(*) INTO v_existing_count 
        FROM agent_swarm.contacts 
        WHERE email ILIKE p_email AND id != v_contact_id;
        
        IF v_existing_count > 0 THEN
            RETURN QUERY SELECT FALSE, v_entity_id, v_contact_id, 
                'Email already in use by another contact';
            RETURN;
        END IF;
    END IF;
    
    -- Check for phone conflict if updating phone
    IF p_phone IS NOT NULL AND p_phone != '' THEN
        SELECT COUNT(*) INTO v_existing_count 
        FROM agent_swarm.contacts 
        WHERE phone = p_phone AND id != v_contact_id;
        
        IF v_existing_count > 0 THEN
            RETURN QUERY SELECT FALSE, v_entity_id, v_contact_id, 
                'Phone number already in use by another contact';
            RETURN;
        END IF;
    END IF;
    
    -- Update contact information
    UPDATE agent_swarm.contacts
    SET 
        first_name = COALESCE(p_first_name, first_name),
        last_name = COALESCE(p_last_name, last_name),
        email = COALESCE(p_email, email),
        phone = COALESCE(p_phone, phone),
        updated_at = NOW()
    WHERE id = v_contact_id;
    
    -- Update entity information - FIXED: Use explicit table alias to avoid ambiguity
    UPDATE agent_swarm.entities ent
    SET 
        name = CASE 
            WHEN p_first_name IS NOT NULL OR p_last_name IS NOT NULL 
            THEN COALESCE(p_first_name, '') || ' ' || COALESCE(p_last_name, '')
            ELSE ent.name
        END,
        status = COALESCE(p_status, ent.status),
        updated_at = NOW()
    WHERE ent.id = v_entity_id;
    
    -- Update or insert address
    IF p_street IS NOT NULL OR p_city IS NOT NULL OR p_state IS NOT NULL OR p_postal_code IS NOT NULL THEN
        -- Update existing primary address
        UPDATE agent_swarm.addresses addr
        SET 
            street = COALESCE(p_street, addr.street),
            city = COALESCE(p_city, addr.city),
            state = COALESCE(p_state, addr.state),
            postal_code = COALESCE(p_postal_code, addr.postal_code),
            country = COALESCE(p_country, addr.country),
            is_primary = TRUE
        WHERE addr.entity_id = v_entity_id AND addr.is_primary = TRUE;
        
        -- If no address exists, insert a new one
        -- FIXED: Use table alias (addr2) to avoid ambiguous column reference
        IF NOT EXISTS (SELECT 1 FROM agent_swarm.addresses addr2 WHERE addr2.entity_id = v_entity_id) THEN
            INSERT INTO agent_swarm.addresses (
                entity_id, contact_id, address_type,
                street, city, state, postal_code, country, is_primary, created_at
            ) VALUES (
                v_entity_id, v_contact_id, 'home',
                COALESCE(p_street, ''), COALESCE(p_city, ''), 
                COALESCE(p_state, ''), COALESCE(p_postal_code, ''),
                COALESCE(p_country, 'US'), TRUE, NOW()
            );
        END IF;
    END IF;
    
    -- Note: audit_log table doesn't exist in the database, so we skip that insert
    -- The update is still logged in the communications table by the Python tool
    
    -- Return success
    RETURN QUERY SELECT TRUE, v_entity_id, v_contact_id, 
        'Customer updated successfully';
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN QUERY SELECT FALSE, NULL::INTEGER, NULL::INTEGER, 
            'Error updating customer: ' || SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Function: Get customers requiring follow-up
CREATE OR REPLACE FUNCTION get_followup_customers(p_days_threshold INTEGER DEFAULT 7)
RETURNS TABLE(
    entity_id INTEGER,
    name TEXT,
    email TEXT,
    phone TEXT,
    last_communication_date TIMESTAMPTZ,
    follow_up_reason TEXT
) AS $$
DECLARE
    rec RECORD;
    last_comm_date TIMESTAMPTZ;
    last_outcome VARCHAR(50);
    v_entity_id INTEGER;
    v_name TEXT;
    v_email TEXT;
    v_phone TEXT;
BEGIN
    FOR rec IN
        SELECT 
            e.id AS ent_id,
            e.name AS ent_name,
            c.email,
            c.phone,
            e.status
        FROM agent_swarm.entities e
        JOIN agent_swarm.entity_relationships er ON e.id = er.entity_id AND er.is_primary = TRUE
        JOIN agent_swarm.contacts c ON er.contact_id = c.id
        WHERE e.entity_type = 'customer'
    LOOP
        -- Get last communication date and outcome
        SELECT MAX(created_at), 
               (SELECT outcome FROM agent_swarm.communications c2 
                WHERE c2.entity_id = rec.ent_id 
                ORDER BY created_at DESC LIMIT 1)
        INTO last_comm_date, last_outcome
        FROM agent_swarm.communications comm
        WHERE comm.entity_id = rec.ent_id;
        
        -- Check follow-up criteria
        IF rec.status = 'follow-up' THEN
            v_entity_id := rec.ent_id;
            v_name := rec.ent_name;
            v_email := rec.email;
            v_phone := rec.phone;
            last_communication_date := last_comm_date;
            follow_up_reason := 'Status marked for follow-up';
            RETURN NEXT;
        ELSIF last_comm_date IS NULL OR last_comm_date < NOW() - INTERVAL '7 days' THEN
            v_entity_id := rec.ent_id;
            v_name := rec.ent_name;
            v_email := rec.email;
            v_phone := rec.phone;
            last_communication_date := last_comm_date;
            follow_up_reason := 'No recent communications';
            RETURN NEXT;
        ELSIF last_outcome IN ('pending', 'escalated') THEN
            v_entity_id := rec.ent_id;
            v_name := rec.ent_name;
            v_email := rec.email;
            v_phone := rec.phone;
            last_communication_date := last_comm_date;
            follow_up_reason := 'Unresolved communication';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION add_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO jarvis;
GRANT EXECUTE ON FUNCTION update_customer TO jarvis;
GRANT EXECUTE ON FUNCTION get_followup_customers(INTEGER) TO jarvis;
