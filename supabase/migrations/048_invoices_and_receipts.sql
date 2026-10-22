

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
  invoice_id uuid NOT NULL
    REFERENCES public.invoices(id) ON DELETE RESTRICT,
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
-- Supports instalments and multiple payments per invoice.
CREATE TABLE IF NOT EXISTS public.payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL
    REFERENCES public.accounts(id) ON DELETE RESTRICT,
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
  SELECT p.amount INTO payment_total
  FROM public.payments p
  WHERE p.id = NEW.payment_id
    AND p.account_id = NEW.account_id
    AND p.status = 'confirmed';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Allocations require a confirmed payment';
  END IF;

  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_payment
  FROM public.payment_allocations pa
  WHERE pa.payment_id = NEW.payment_id
    AND pa.account_id = NEW.account_id
    AND (TG_OP = 'INSERT' OR pa.id <> NEW.id);

  IF allocated_payment + NEW.amount > payment_total THEN
    RAISE EXCEPTION 'Allocations cannot exceed the confirmed payment amount';
  END IF;

  SELECT i.total INTO invoice_total
  FROM public.invoices i
  WHERE i.id = NEW.invoice_id
    AND i.account_id = NEW.account_id
    AND i.status <> 'void';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found or is void';
  END IF;

  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_invoice
  FROM public.payment_allocations pa
  WHERE pa.invoice_id = NEW.invoice_id
    AND pa.account_id = NEW.account_id
    AND (TG_OP = 'INSERT' OR pa.id <> NEW.id);

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

-- Receipt creation is allowed only for confirmed payments.
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
  SELECT p.amount INTO payment_total
  FROM public.payments p
  WHERE p.id = NEW.payment_id
    AND p.account_id = NEW.account_id
    AND p.status = 'confirmed';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Allocations require a confirmed payment';
  END IF;

  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_payment
  FROM public.payment_allocations pa
  WHERE pa.payment_id = NEW.payment_id
    AND pa.account_id = NEW.account_id
    AND (TG_OP = 'INSERT' OR pa.id <> NEW.id);

  IF allocated_payment + NEW.amount > payment_total THEN
    RAISE EXCEPTION 'Allocations cannot exceed the confirmed payment amount';
  END IF;

  SELECT i.total INTO invoice_total
  FROM public.invoices i
  WHERE i.id = NEW.invoice_id
    AND i.account_id = NEW.account_id
    AND i.status <> 'void';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found or is void';
  END IF;

  SELECT COALESCE(SUM(pa.amount), 0)
    INTO allocated_invoice
  FROM public.payment_allocations pa
  WHERE pa.invoice_id = NEW.invoice_id
    AND pa.account_id = NEW.account_id
    AND (TG_OP = 'INSERT' OR pa.id <> NEW.id);

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


  RETURN NEW;


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
ON public.invoices FOR INSERT TO authenticated
WITH CHECK (public.is_account_member(account_id, 'agent'));

CREATE POLICY "Billing agents can update invoices"
ON public.invoices FOR UPDATE TO authenticated
USING (public.is_account_member(account_id, 'agent'))
WITH CHECK (public.is_account_member(account_id, 'agent'));

-- Invoice items inherit access from their parent invoice.
CREATE POLICY "Billing members can view invoice items"
ON public.invoice_items FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.invoices i
  WHERE i.id = invoice_id
    AND public.is_account_member(i.account_id, 'viewer')
));

CREATE POLICY "Billing agents can add invoice items"
ON public.invoice_items FOR INSERT TO authenticated
WITH CHECK (EXISTS (
  SELECT 1 FROM public.invoices i
  WHERE i.id = invoice_id
    AND i.status = 'draft'
    AND public.is_account_member(i.account_id, 'agent')
));

CREATE POLICY "Billing agents can update draft invoice items"
ON public.invoice_items FOR UPDATE TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.invoices i
  WHERE i.id = invoice_id
    AND i.status = 'draft'
    AND public.is_account_member(i.account_id, 'agent')
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.invoices i
  WHERE i.id = invoice_id
    AND i.status = 'draft'
    AND public.is_account_member(i.account_id, 'agent')
));

-- Payments: members can read; agents and above can record/update.
CREATE POLICY "Billing members can view payments"
ON public.payments FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

CREATE POLICY "Billing agents can create payments"
ON public.payments FOR INSERT TO authenticated
WITH CHECK (public.is_account_member(account_id, 'agent'));


-- Allocations: restrict access to the matching business account.
CREATE POLICY "Billing members can view allocations"
ON public.payment_allocations FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

CREATE POLICY "Billing agents can create allocations"
ON public.payment_allocations FOR INSERT TO authenticated
WITH CHECK (public.is_account_member(account_id, 'agent'));

-- Receipts: members can read; server-side service role can issue receipts.
CREATE POLICY "Billing members can view receipts"
ON public.invoice_receipts FOR SELECT TO authenticated
USING (public.is_account_member(account_id, 'viewer'));

COMMIT;



