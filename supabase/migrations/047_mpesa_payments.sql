
-- M-Pesa payment records for M-BizLipa.
-- Never store consumer secrets or passkeys in these tables.

CREATE TABLE IF NOT EXISTS public.mpesa_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL
    REFERENCES public.accounts(id) ON DELETE RESTRICT,
  checkout_request_id text UNIQUE,
  merchant_request_id text,
  mpesa_receipt_number text UNIQUE,
  phone_number text,
  amount numeric(12, 2) NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'KES' CHECK (currency = 'KES'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN (
      'pending', 'processing', 'completed', 'failed', 'cancelled'
    )),
  result_code text,
  result_description text,
  transaction_date timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mpesa_payments_account_created
  ON public.mpesa_payments (account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_mpesa_payments_status
  ON public.mpesa_payments (status);

-- Store callback events for server-side processing.
CREATE TABLE IF NOT EXISTS public.mpesa_callback_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checkout_request_id text,
  payload jsonb NOT NULL,
  processed boolean NOT NULL DEFAULT false,
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mpesa_callback_events_checkout
  ON public.mpesa_callback_events (checkout_request_id);

-- Protect payment data from cross-account access.
ALTER TABLE public.mpesa_payments
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.mpesa_callback_events
  ENABLE ROW LEVEL SECURITY;

-- Business members can view payments belonging to their account.
DROP POLICY IF EXISTS "Account members can view their M-Pesa payments"
  ON public.mpesa_payments;

CREATE POLICY "Account members can view their M-Pesa payments"
  ON public.mpesa_payments
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.user_id = auth.uid()
        AND p.account_id = mpesa_payments.account_id
    )
  );
