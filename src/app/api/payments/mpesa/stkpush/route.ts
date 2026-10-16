import { NextResponse } from 'next/server'

export const runtime = 'nodejs'

export async function POST(request: Request) {
  let body: { phone?: string; amount?: number }

  try {
    body = await request.json()
  } catch {
    return NextResponse.json(
      { error: 'Invalid JSON body' },
      { status: 400 },
    )
  }

  const phone = body.phone?.trim()
  const amount = body.amount

  if (
    !phone ||
    !/^254[17]\d{8}$/.test(phone) ||
    typeof amount !== 'number' ||
    !Number.isFinite(amount) ||
    amount <= 0
  ) {
    return NextResponse.json(
      {
        error:
          'Enter a valid Kenyan phone number starting with 254 and a positive amount.',
      },
      { status: 400 },
    )
  }

  // Daraja STK Push will be implemented in the next step.
  // This placeholder deliberately does not initiate a payment.
  return NextResponse.json(
    {
      message: 'Input validated. M-Pesa integration is not active yet.',
    },
    { status: 501 },
  )
}
