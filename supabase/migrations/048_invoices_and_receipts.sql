M-BizLipa billing: invoices and invoice items
-- Migration: 048_invoices_and_receipts.sql

CREATE TABLE IF NOT EXISTS public.invoices (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
account_id uuid NOT NULL
REFERENCES public.accounts(id) ON DELETE RESTRICT,
contact_id uuid
REFERENCES public.contacts(id) ON DELETE RESTRICT,
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
CHECK (due_date IS NULL OR due_date >= issue_date)
);

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

CREATE INDEX IF NOT EXISTS idx_invoices_account_created
ON public.invoices (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_invoices_account_status
ON public.invoices (account_id, status);

CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice
ON public.invoice_items (invoice_id);
-- Payment tracking and customer receipts

CREATE TABLE IF NOT EXISTS public.payments (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
account_id uuid NOT NULL
REFERENCES public.accounts(id) ON DELETE RESTRICT,
method text NOT NULL
CHECK (method IN (
'mpesa', 'cash', 'bank_transfer', 'other'
)),
amount numeric(12,2) NOT NULL CHECK (amount > 0),
currency text NOT NULL DEFAULT 'KES'
CHECK (currency = 'KES'),
status text NOT NULL DEFAULT 'pending'
CHECK (status IN (
'pending', 'confirmed', 'failed', 'refunded'
)),
reference text,
mpesa_payment_id uuid
REFERENCES public.mpesa_payments(id) ON DELETE RESTRICT,
received_at timestamptz,
recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.payment_allocations (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
account_id uuid NOT NULL
REFERENCES public.accounts(id) ON DELETE RESTRICT,
payment_id uuid NOT NULL
REFERENCES public.payments(id) ON DELETE RESTRICT,
invoice_id uuid NOT NULL
REFERENCES public.invoices(id) ON DELETE RESTRICT,
amount numeric(12,2) NOT NULL CHECK (amount > 0),
created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.invoice_receipts (
id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
account_id uuid NOT NULL
REFERENCES public.accounts(id) ON DELETE RESTRICT,
payment_id uuid NOT NULL UNIQUE
REFERENCES public.payments(id) ON DELETE RESTRICT,
receipt_number text NOT NULL,
amount numeric(12,2) NOT NULL CHECK (amount > 0),
currency text NOT NULL DEFAULT 'KES'
CHECK (currency = 'KES'),
issued_at timestamptz NOT NULL DEFAULT now(),
created_at timestamptz NOT NULL DEFAULT now(),
UNIQUE (account_id, receipt_number)
);

CREATE INDEX IF NOT EXISTS idx_payments_account_created
ON public.payments (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_payment_allocations_invoice
ON public.payment_allocations (invoice_id);

CREATE INDEX IF NOT EXISTS idx_payment_allocations_payment
ON public.payment_allocations (payment_id);

CREATE INDEX IF NOT EXISTS idx_invoice_receipts_account
ON public.invoice_receipts (account_id, issued_at DESC);
