 

-- M-BizLipa billing tables
-- Migration 048: invoices, payments, allocations and receipts
-- Do not run until reviewed and backed up.

BEGIN;

-- Support account-safe foreign keys to existing records.
CREATE UNIQUE INDEX IF NOT EXISTS idx_contacts_id_account_unique
  ON public.contacts (id, account_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_mpesa_payments_id_account_unique
  ON public.mpesa_payments (id, account_id);

-- 1. Invoices
CREATE TABLE IF NOT EXISTS public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL
    REFERENCES public.accounts(id) ON DELETE RESTRICT,
  contact_id uuid,
  invoice_number text NOT NULL,
  customer_name text NOT NULL,
  customer_phone text,
  customer_email text,
  currency text NOT NULL DEFAULT 'KES'
    CHECK (currency = 'KES'),
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN (
      'draft', 'issued', 'partially_paid',
      'paid', 'overdue', 'void'
    )),
  issue_date date NOT NULL DEFAULT CURRENT_DATE,
  due_date date,
  subtotal numeric(12,2) NOT NULL DEFAULT 0
    CHECK (subtotal >= 0),
  tax_total numeric(12,2) NOT NULL DEFAULT 0
    CHECK (tax_total >= 0),
  discount_total numeric(12,2) NOT NULL DEFAULT 0
    CHECK (discount_total >= 0),
  total numeric(12,2) NOT NULL DEFAULT 0
    CHECK (total >= 0),
  notes text,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, invoice_number),
  UNIQUE (id, account_id),
  FOREIGN KEY (contact_id, account_id)
    REFERENCES public.contacts(id, account_id)
    ON DELETE RESTRICT,
  CHECK (due_date IS NULL OR due_date >= issue_date)
);

-- 2. Invoice line items
CREATE TABLE IF NOT EXISTS public.invoice_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL,
account_id uuid NOT NULL,
FOREIGN KEY (invoice_id, account_id)
  REFERENCES public.invoices(id, account_id)
  ON DELETE RESTRICT,
  description text NOT NULL,
  quantity numeric(12,3) NOT NULL CHECK (quantity > 0),
  unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  tax_amount numeric(12,2) NOT NULL DEFAULT 0
    CHECK (tax_amount >= 0),
  discount_amount numeric(12,2) NOT NULL DEFAULT 0
    CHECK (discount_amount >= 0),
  line_total numeric(12,2) NOT NULL CHECK (line_total >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
-- Keep invoice totals synchronized with line.
CREATE OR REPLACE FUNCTION public.recalculate_mbizlipa_invoice_totals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  target_invoice_id uuid;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.invoice_id IS DISTINCT FROM NEW.invoice_id THEN

    UPDATE public.invoices i
    SET
      subtotal = totals.subtotal,
      tax_total = totals.tax_total,
      discount_total = totals.discount_total,
      total = totals.total,
      updated_at = now()
    FROM (
      SELECT
        COALESCE(SUM(quantity * unit_price), 0)::numeric(12,2) AS subtotal,
        COALESCE(SUM(tax_amount), 0)::numeric(12,2) AS tax_total,
        COALESCE(SUM(discount_amount), 0)::numeric(12,2) AS discount_total,
        COALESCE(SUM(line_total), 0)::numeric(12,2) AS total
      FROM public.invoice_items
WHERE invoice_id = OLD.invoice_id
  AND account_id = OLD.account_id
    ) totals
WHERE i.id = OLD.invoice_id
  AND i.account_id = OLD.account_id
  AND i.status = 'draft';

    target_invoice_id := NEW.invoice_id;
  ELSIF TG_OP = 'DELETE' THEN
    target_invoice_id := OLD.invoice_id;
  ELSE
    target_invoice_id := NEW.invoice_id;
  END IF;

  UPDATE public.invoices i
  SET
    subtotal = totals.subtotal,
    tax_total = totals.tax_total,
    discount_total = totals.discount_total,
    total = totals.total,
    updated_at = now()
  FROM (
    SELECT
      COALESCE(SUM(quantity * unit_price), 0)::numeric(12,2) AS subtotal,
      COALESCE(SUM(tax_amount), 0)::numeric(12,2) AS tax_total,
      COALESCE(SUM(discount_amount), 0)::numeric(12,2) AS discount_total,
      COALESCE(SUM(line_total), 0)::numeric(12,2) AS total
    FROM public.invoice_items
    WHERE invoice_id = target_invoice_id
  AND account_id = CASE
    WHEN TG_OP = 'DELETE' THEN OLD.account_id
    ELSE NEW.account_id
  END
  ) totals
 WHERE i.id = target_invoice_id
  AND i.account_id = CASE
    WHEN TG_OP = 'DELETE' THEN OLD.account_id
    ELSE NEW.account_id
  END
  AND i.status = 'draft'; 

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_recalculate_mbizlipa_invoice_totals
AFTER INSERT OR UPDATE OR DELETE ON public.invoice_items
FOR EACH ROW
EXECUTE FUNCTION public.recalculate_mbizlipa_invoice_totals();

CREATE OR REPLACE FUNCTION public.issue_mbizlipa_invoice(
  p_invoice_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_account_id uuid;
BEGIN
  SELECT i.account_id
  INTO target_account_id
  FROM public.invoices i
  WHERE i.id = p_invoice_id
    AND i.status = 'draft'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Draft invoice not found';
  END IF;

  IF NOT public.is_account_member(target_account_id, 'agent') THEN
    RAISE EXCEPTION 'Not authorized to issue this invoice';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.invoice_items ii
    WHERE ii.invoice_id = p_invoice_id
      AND ii.account_id = target_account_id
  ) THEN
    RAISE EXCEPTION 'Cannot issue an invoice without invoice items';
  END IF;

  UPDATE public.invoices
  SET
    status = 'issued',
    updated_at = now()
  WHERE id = p_invoice_id
    AND account_id = target_account_id
    AND status = 'draft';
END;
$$;

REVOKE ALL ON FUNCTION public.issue_mbizlipa_invoice(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.issue_mbizlipa_invoice(uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.calculate_mbizlipa_invoice_item_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.line_total := ROUND(
    (NEW.quantity * NEW.unit_price)
    + NEW.tax_amount
    - NEW.discount_amount,
    2
  );

  IF NEW.line_total < 0 THEN
    RAISE EXCEPTION 'Discount cannot exceed quantity times unit price plus tax';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_calculate_invoice_item_total
BEFORE INSERT OR UPDATE
ON public.invoice_items
FOR EACH ROW
EXECUTE FUNCTION public.calculate_mbizlipa_invoice_item_total();

-- 3. Payment records
CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL
    REFERENCES public.accounts(id) ON DELETE RESTRICT,
  method text NOT NULL
    CHECK (method IN ('mpesa', 'cash', 'bank_transfer', 'other')),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'KES'
    CHECK (currency = 'KES'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'failed', 'refunded')),
  reference text,
  mpesa_payment_id uuid UNIQUE,
  received_at timestamptz,
  recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, account_id),
  FOREIGN KEY (mpesa_payment_id, account_id)
    REFERENCES public.mpesa_payments(id, account_id)
    ON DELETE RESTRICT
);

-- 4. Allocate payments to invoices.

CREATE TABLE IF NOT EXISTS public.payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
  payment_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (payment_id, account_id)
    REFERENCES public.payments(id, account_id)
    ON DELETE RESTRICT,
  FOREIGN KEY (invoice_id, account_id)
    REFERENCES public.invoices(id, account_id)
    ON DELETE RESTRICT
);
  
CREATE OR REPLACE FUNCTION public.validate_mbizlipa_allocation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  payment_total numeric(12,2);
  allocated_payment numeric(12,2);
  invoice_total numeric(12,2);
  allocated_invoice numeric(12,2);
BEGIN
  IF NEW.amount <= 0 THEN
    RAISE EXCEPTION 'Allocation amount must be greater than zero';
  END IF;
  SELECT p.amount INTO payment_total
FROM public.payments p
WHERE p.id = NEW.payment_id
  AND p.account_id = NEW.account_id
  AND p.status = 'confirmed'
FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Allocations require a confirmed payment';
  END IF;

  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_payment
  FROM public.payment_allocations pa
  WHERE pa.payment_id = NEW.payment_id
    AND pa.account_id = NEW.account_id
    AND (TG_OP = 'INSERT' OR pa.id <> OLD.id);

  IF allocated_payment + NEW.amount > payment_total THEN
   RAISE EXCEPTION 'Total allocations cannot exceed the confirmed payment amount'; 
  END IF;

  SELECT i.total INTO invoice_total
  FROM public.invoices i
  WHERE i.id = NEW.invoice_id
    AND i.account_id = NEW.account_id
   AND i.status NOT IN ('draft', 'void')
FOR UPDATE; 

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Total allocations cannot exceed the invoice total';
  END IF;

  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_invoice
  FROM public.payment_allocations pa
  WHERE pa.invoice_id = NEW.invoice_id
    AND pa.account_id = NEW.account_id
    AND (TG_OP = 'INSERT' OR pa.id <> OLD.id);

  IF allocated_invoice + NEW.amount > invoice_total THEN
    RAISE EXCEPTION 'Allocations cannot exceed the invoice total';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_mbizlipa_allocation
BEFORE INSERT OR UPDATE ON public.payment_allocations
FOR EACH ROW
EXECUTE FUNCTION public.validate_mbizlipa_allocation();
-- Prevent changes to allocations after a receipt has been 
CREATE OR REPLACE FUNCTION public.prevent_allocation_changes_after_receipt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM 1
    FROM public.payments p
    WHERE p.id = OLD.payment_id
      AND p.account_id = OLD.account_id
    FOR UPDATE;

    IF EXISTS (
      SELECT 1
      FROM public.invoice_receipts r
      WHERE r.payment_id = OLD.payment_id
        AND r.account_id = OLD.account_id
    ) THEN
      RAISE EXCEPTION
        'Payment allocations cannot be changed after a receipt has been issued';
    END IF;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM 1
    FROM public.payments p
    WHERE p.id = NEW.payment_id
      AND p.account_id = NEW.account_id
    FOR UPDATE;

    IF EXISTS (
      SELECT 1
      FROM public.invoice_receipts r
      WHERE r.payment_id = NEW.payment_id
        AND r.account_id = NEW.account_id
    ) THEN
      RAISE EXCEPTION
        'Payment allocations cannot be changed after a receipt has been issued';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prevent_allocation_changes_after_receipt
BEFORE INSERT OR UPDATE OR DELETE
ON public.payment_allocations
FOR EACH ROW
EXECUTE FUNCTION public.prevent_allocation_changes_after_receipt();
  

-- 5. Customer-facing receipts.
-- Different from the Safaricom M-Pesa receipt number.
CREATE TABLE IF NOT EXISTS public.invoice_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL
    REFERENCES public.accounts(id) ON DELETE RESTRICT,
  payment_id uuid NOT NULL UNIQUE,
  receipt_number text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'KES'
    CHECK (currency = 'KES'),
  issued_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, receipt_number),
  FOREIGN KEY (payment_id, account_id)
    REFERENCES public.payments(id, account_id)
    ON DELETE RESTRICT
);
CREATE SEQUENCE IF NOT EXISTS public.mbizlipa_receipt_number_seq
START WITH 1
INCREMENT BY 1;

GRANT USAGE ON SEQUENCE public.mbizlipa_receipt_number_seq TO authenticated;

CREATE OR REPLACE FUNCTION public.generate_mbizlipa_receipt_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.receipt_number := 'MBR-' || LPAD(
    nextval('public.mbizlipa_receipt_number_seq')::text,
    8,
    '0'
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_generate_mbizlipa_receipt_number
BEFORE INSERT ON public.invoice_receipts
FOR EACH ROW
EXECUTE FUNCTION public.generate_mbizlipa_receipt_number();

-- Useful indexes
CREATE INDEX IF NOT EXISTS idx_invoices_account_created
  ON public.invoices (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_invoices_account_status
  ON public.invoices (account_id, status);

CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice
  ON public.invoice_items (invoice_id);

CREATE INDEX IF NOT EXISTS idx_payments_account_created
  ON public.payments (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_payment_allocations_invoice
  ON public.payment_allocations (invoice_id);

CREATE INDEX IF NOT EXISTS idx_payment_allocations_payment
  ON public.payment_allocations (payment_id);

CREATE INDEX IF NOT EXISTS idx_invoice_receipts_account
  ON public.invoice_receipts (account_id, issued_at DESC);

CREATE OR REPLACE FUNCTION public.recalculate_mbizlipa_invoice_payment_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_invoice_id uuid;
  target_account_id uuid;
  affected_invoice_ids uuid[];
  affected_account_ids uuid[];
  invoice_total numeric(12,2);
  invoice_due_date date;
  allocated_total numeric(12,2);
  item_index integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    affected_invoice_ids := ARRAY[OLD.invoice_id];
    affected_account_ids := ARRAY[OLD.account_id];

  ELSIF TG_OP = 'UPDATE'
        AND (
          OLD.invoice_id IS DISTINCT FROM NEW.invoice_id
          OR OLD.account_id IS DISTINCT FROM NEW.account_id
        ) THEN
    affected_invoice_ids := ARRAY[
      OLD.invoice_id, NEW.invoice_id
    ];
    affected_account_ids := ARRAY[
      OLD.account_id, NEW.account_id
    ];

  ELSE
    affected_invoice_ids := ARRAY[NEW.invoice_id];
    affected_account_ids := ARRAY[NEW.account_id];
  END IF;

  FOR item_index IN 1..array_length(affected_invoice_ids, 1)
  LOOP
    target_invoice_id := affected_invoice_ids[item_index];
    target_account_id := affected_account_ids[item_index];

    SELECT i.total, i.due_date
INTO invoice_total, invoice_due_date
FROM public.invoices i
WHERE i.id = target_invoice_id
  AND i.account_id = target_account_id;

IF NOT FOUND THEN
  CONTINUE;
END IF;
    
  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_total
    FROM public.payment_allocations pa
    JOIN public.payments p
      ON p.id = pa.payment_id
     AND p.account_id = pa.account_id
    WHERE pa.invoice_id = target_invoice_id
      AND pa.account_id = target_account_id
      AND p.status = 'confirmed';

    UPDATE public.invoices
    SET status = CASE
  WHEN allocated_total >= invoice_total THEN 'paid'
  WHEN allocated_total > 0 THEN 'partially_paid'
  WHEN invoice_due_date < CURRENT_DATE THEN 'overdue'
    ELSE 'issued'
END,
     
    updated_at = now()
    WHERE id = target_invoice_id
      AND account_id = target_account_id
      AND status NOT IN ('void', 'draft');
  END LOOP;

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_recalculate_invoice_payment_status
AFTER INSERT OR UPDATE OR DELETE ON public.payment_allocations
FOR EACH ROW
EXECUTE FUNCTION public.recalculate_mbizlipa_invoice_payment_status();

REVOKE ALL ON FUNCTION public.recalculate_mbizlipa_invoice_payment_status()
FROM PUBLIC, anon, authenticated;

-- Receipt creation is allowed only for confirmed payments.
CREATE OR REPLACE FUNCTION public.recalculate_invoices_after_payment_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  affected_invoice record;
BEGIN
  FOR affected_invoice IN
    SELECT DISTINCT pa.invoice_id
    FROM public.payment_allocations pa
    WHERE pa.payment_id = NEW.id
      AND pa.account_id = NEW.account_id
  LOOP
    UPDATE public.invoices i
    SET status = CASE
  WHEN totals.allocated_total >= i.total THEN 'paid'
  WHEN totals.allocated_total > 0 THEN 'partially_paid'
  WHEN i.due_date < CURRENT_DATE THEN 'overdue'
    ELSE 'issued'
END,
    updated_at = now()
    FROM (
      SELECT COALESCE(SUM(pa.amount), 0) AS allocated_total
      FROM public.payment_allocations pa
      JOIN public.payments p
        ON p.id = pa.payment_id
       AND p.account_id = pa.account_id
      WHERE pa.invoice_id = affected_invoice.invoice_id
        AND pa.account_id = NEW.account_id
        AND p.status = 'confirmed'
    ) totals
    WHERE i.id = affected_invoice.invoice_id
      AND i.account_id = NEW.account_id
      AND i.status NOT IN ('draft', 'void');
  END LOOP;

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_recalculate_invoices_after_payment_status_change
AFTER UPDATE OF status ON public.payments
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.recalculate_invoices_after_payment_status_change();

REVOKE ALL ON FUNCTION public.recalculate_invoices_after_payment_status_change()
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.validate_mbizlipa_receipt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  payment_status text;
  payment_amount numeric(12,2);
BEGIN
  SELECT p.status, p.amount
  INTO payment_status, payment_amount
  FROM public.payments p
  WHERE p.id = NEW.payment_id
    AND p.account_id = NEW.account_id
FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment not found';
  END IF;

  IF payment_status <> 'confirmed' THEN
    RAISE EXCEPTION 'Receipts can only be issued for confirmed payments';
  END IF;

  IF NEW.amount <> payment_amount THEN
    RAISE EXCEPTION 'Receipt amount must match the confirmed payment amount';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_mbizlipa_receipt
BEFORE INSERT OR UPDATE ON public.invoice_receipts
FOR EACH ROW
EXECUTE FUNCTION public.validate_mbizlipa_receipt();

CREATE OR REPLACE FUNCTION public.prevent_invalid_receipt_payment_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status <> 'confirmed'
     AND EXISTS (
       SELECT 1
       FROM public.invoice_receipts r
       WHERE r.payment_id = NEW.id
         AND r.account_id = NEW.account_id
     )
  THEN
    RAISE EXCEPTION
      'A payment with an issued receipt cannot be marked failed, refunded or pending';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prevent_invalid_receipt_payment_status
BEFORE UPDATE OF status ON public.payments
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.prevent_invalid_receipt_payment_status();
-- Enable row-level security.
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_receipts ENABLE ROW LEVEL SECURITY;

-- Invoices: account members can read; agents and above can create/edit.
CREATE POLICY "Billing members can view invoices"
ON public.invoices FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

CREATE POLICY "Billing agents can create invoices"
ON public.invoices
FOR INSERT TO authenticated
WITH CHECK (
  public.is_account_member(account_id, 'agent')
  AND status = 'draft'
);

CREATE POLICY "Billing agents can update invoices"
ON public.invoices
FOR UPDATE TO authenticated
USING (
  public.is_account_member(account_id, 'agent')
  AND status = 'draft'
)
WITH CHECK (
  public.is_account_member(account_id, 'agent')
  AND status = 'draft'
);

-- Invoice items inherit access from their parent invoice.
CREATE POLICY "Billing members can view invoice items"
ON public.invoice_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.invoices i
    WHERE i.id = invoice_items.invoice_id
      AND i.account_id = invoice_items.account_id
      AND public.is_account_member(i.account_id, 'viewer')
  )
);

CREATE POLICY "Billing agents can add invoice items"
ON public.invoice_items
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.invoices i
WHERE i.id = invoice_items.invoice_id
      AND i.account_id = invoice_items.account_id
      AND i.status = 'draft'
      AND public.is_account_member(i.account_id, 'agent')
  )
);
CREATE POLICY "Billing agents can update draft invoice items"
ON public.invoice_items
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.invoices i
    WHERE i.id = invoice_items.invoice_id
      AND i.account_id = invoice_items.account_id
      AND i.status = 'draft'
      AND public.is_account_member(i.account_id, 'agent')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.invoices i
    WHERE i.id = invoice_items.invoice_id
      AND i.account_id = invoice_items.account_id
      AND i.status = 'draft'
      AND public.is_account_member(i.account_id, 'agent')
  )
);

CREATE POLICY "Billing agents can delete draft invoice items"
ON public.invoice_items
FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.invoices i
    WHERE i.id = invoice_items.invoice_id
      AND i.account_id = invoice_items.account_id
      AND i.status = 'draft'
      AND public.is_account_member(i.account_id, 'agent')
  )
);

-- Payments: members can read; agents can record.
-- Payment status updates are handled server-side.
CREATE POLICY "Billing members can view payments"
ON public.payments FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

CREATE POLICY "Billing agents can create payments"
ON public.payments
FOR INSERT TO authenticated
WITH CHECK (
  public.is_account_member(account_id, 'agent')
  AND status = 'pending'
);


-- Allocations: restrict access to the matching business account.
CREATE POLICY "Billing members can view allocations"
ON public.payment_allocations FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

CREATE POLICY "Billing agents can create allocations"
ON public.payment_allocations
FOR INSERT TO authenticated
WITH CHECK (
  public.is_account_member(account_id, 'agent')
  AND EXISTS (
    SELECT 1
    FROM public.invoices i
WHERE i.id = payment_allocations.invoice_id
      AND i.account_id = payment_allocations.account_id
      AND i.status NOT IN ('draft', 'void')
  )
);

CREATE POLICY "Billing agents can update allocations"
ON public.payment_allocations
FOR UPDATE TO authenticated
USING (
  public.is_account_member(account_id, 'agent')
)
WITH CHECK (
  public.is_account_member(account_id, 'agent')
  AND EXISTS (
    SELECT 1
    FROM public.invoices i
    WHERE i.id = payment_allocations.invoice_id
      AND i.account_id = payment_allocations.account_id
      AND i.status NOT IN ('draft', 'void')
  )
);

-- Receipts: members can read; billing agents can issue receipts.
CREATE POLICY "Billing members can view receipts"
ON public.invoice_receipts FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

CREATE POLICY "Billing agents can create receipts"
ON public.invoice_receipts
FOR INSERT TO authenticated
WITH CHECK (
  public.is_account_member(account_id, 'agent')
  AND EXISTS (
    SELECT 1
    FROM public.payment_allocations pa
    WHERE pa.payment_id = invoice_receipts.payment_id
      AND pa.account_id = invoice_receipts.account_id
  )
);


COMMIT;












