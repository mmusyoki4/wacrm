
import { NextResponse } from 'next/server'

export const runtime = 'nodejs'

type MpesaCallback = {
  Body?: {
    stkCallback?: {
      MerchantRequestID?: string
      CheckoutRequestID?: string
      ResultCode?: number
      ResultDesc?: string
      CallbackMetadata?: {
        Item?: Array<{
          Name?: string
          Value?: string | number
        }>
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

  if (!callback?.CheckoutRequestID ||
      typeof callback.ResultCode !== 'number') {
    return NextResponse.json(
      { error: 'Invalid M-Pesa callback structure' },
      { status: 400 },
    )
  }

  // A valid structure does not prove that a payment is genuine.
  // Do not mark payments as completed in this handler yet.
  console.info('M-Pesa callback received', {
    checkoutRequestId: callback.CheckoutRequestID,
    resultCode: callback.ResultCode,
  })

  return NextResponse.json({ ResultCode: 0, ResultDesc: 'Accepted' })
}
