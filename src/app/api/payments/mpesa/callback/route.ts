
import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'

export const runtime = 'nodejs'

function supabaseAdmin() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY

  if (!url || !key) {
    throw new Error('Supabase server configuration is missing')
  }

  return createClient(url, key)
}

type CallbackItem = {
  Name?: string
  Value?: string | number
}

type MpesaCallback = {
  Body?: {
    stkCallback?: {
      MerchantRequestID?: string
      CheckoutRequestID?: string
      ResultCode?: number
      ResultDesc?: string
      CallbackMetadata?: {
        Item?: CallbackItem[]
      }
    }
  }
}

export async function POST(request: Request) {
  let payload: MpesaCallback

  try {
    payload = await request.json()
  } catch {
    return NextResponse.json(
      { error: 'Invalid JSON payload' },
      { status: 400 },
    )
  }

  const callback = payload?.Body?.stkCallback
  const checkoutId = callback?.CheckoutRequestID
  const resultCode = callback?.ResultCode

  if (
    !checkoutId ||
    typeof resultCode !== 'number' ||
    !Number.isFinite(resultCode)
  ) {
    return NextResponse.json(
      { error: 'Invalid M-Pesa callback structure' },
      { status: 400 },
    )
  }

  const items = callback.CallbackMetadata?.Item ?? []
  const getItem = (name: string) =>
    items.find((item) => item.Name === name)?.Value

  const receiptValue = getItem('MpesaReceiptNumber')
  const amountValue = getItem('Amount')
  const phoneValue = getItem('PhoneNumber')
  const dateValue = getItem('TransactionDate')

  const receipt =
    typeof receiptValue === 'string' ? receiptValue : null

  let transactionDate: string | null = null

  if (
    typeof dateValue === 'number' ||
    (typeof dateValue === 'string' && /^\d{14}$/.test(dateValue))
  ) {
    const digits = String(dateValue)

    const iso =
      `${digits.slice(0, 4)}-${digits.slice(4, 6)}-${digits.slice(6, 8)}` +
      `T${digits.slice(8, 10)}:${digits.slice(10, 12)}:${digits.slice(12, 14)}+03:00`

    const parsedDate = new Date(iso)

    if (!Number.isNaN(parsedDate.getTime())) {
      transactionDate = parsedDate.toISOString()
    }
  }

  const admin = supabaseAdmin()

  // Store the event first, including callbacks that cannot yet be matched.
  const { data: event, error: eventError } = await admin
    .from('mpesa_callback_events')
    .insert({
      checkout_request_id: checkoutId,
      payload,
      processed: false,
    })
    .select('id')
    .single()

  if (eventError || !event) {
    console.error('Could not store M-Pesa callback event')
    return NextResponse.json(
      { error: 'Could not store callback event' },
      { status: 500 },
    )
  }

  const paymentStatus = resultCode === 0 ? 'completed' : 'failed'

  const update: Record<string, unknown> = {
    status: paymentStatus,
    result_code: String(resultCode),
    result_description: callback.ResultDesc ?? null,
    updated_at: new Date().toISOString(),
  }

  if (resultCode === 0) {
    if (receipt) update.mpesa_receipt_number = receipt
    if (transactionDate) update.transaction_date = transactionDate

    if (typeof amountValue === 'number') {
      update.amount = amountValue
    }

    if (typeof phoneValue === 'number' || typeof phoneValue === 'string') {
      update.phone_number = String(phoneValue)
    }
  }

  const { data: payments, error: paymentError } = await admin
    .from('mpesa_payments')
    .update(update)
    .eq('checkout_request_id', checkoutId)
    .eq('status', 'processing')
    .select('id')

  if (paymentError) {
    console.error('Could not update M-Pesa payment')
    return NextResponse.json(
      { error: 'Could not update payment status' },
      { status: 500 },
    )
  }

  if (!payments || payments.length === 0) {
    // Keep the event unprocessed for later investigation or reconciliation.
    console.warn('Unmatched M-Pesa callback received')
    return NextResponse.json(
      { ResultCode: 0, ResultDesc: 'Received for reconciliation' },
    )
  }

  const { error: eventUpdateError } = await admin
    .from('mpesa_callback_events')
    .update({ processed: true })
    .eq('id', event.id)

  if (eventUpdateError) {
    console.error('Could not mark callback event as processed')
    return NextResponse.json(
      { error: 'Payment updated but callback event needs reconciliation' },
      { status: 500 },
    )
  }

  return NextResponse.json({
    ResultCode: 0,
    ResultDesc: 'Accepted',
  })
}

