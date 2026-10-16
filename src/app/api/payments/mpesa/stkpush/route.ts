
import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'
import { createClient as createUserClient } from '@/lib/supabase/server'

export const runtime = 'nodejs'

function supabaseAdmin() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY

  if (!url || !key) {
    throw new Error('Supabase server configuration is missing')
  }

  return createClient(url, key)
}

function normalizePhone(value: string): string | null {
  const digits = value.replace(/\D/g, '')
  if (/^254[17]\d{8}$/.test(digits)) return digits
  if (/^0[17]\d{8}$/.test(digits)) return `254${digits.slice(1)}`
  if (/^[17]\d{8}$/.test(digits)) return `254${digits}`
  return null
}

export async function POST(request: Request) {
  try {
    const userClient = await createUserClient()
    const { data: { user }, error: authError } =
      await userClient.auth.getUser()

    if (authError || !user) {
      return NextResponse.json(
        { error: 'Please sign in before initiating a payment.' },
        { status: 401 },
      )
    }

    let body: { phone?: string; amount?: number }

    try {
      body = await request.json()
    } catch {
      return NextResponse.json(
        { error: 'Invalid JSON body.' },
        { status: 400 },
      )
    }

    const phone = typeof body.phone === 'string'
      ? normalizePhone(body.phone)
      : null
    const amount = body.amount

    if (
      !phone ||
      typeof amount !== 'number' ||
      !Number.isSafeInteger(amount) ||
      amount < 1 ||
      amount > 150000
    ) {
      return NextResponse.json(
        { error: 'Enter a valid Kenyan phone number and a whole KES amount from 1 to 150000.' },
        { status: 400 },
      )
    }

    const consumerKey = process.env.MPESA_CONSUMER_KEY
    const consumerSecret = process.env.MPESA_CONSUMER_SECRET
    const shortcode = process.env.MPESA_SHORTCODE
    const passkey = process.env.MPESA_PASSKEY
    const callbackUrl = process.env.MPESA_CALLBACK_URL
    const environment = process.env.MPESA_ENV

    if (
      !consumerKey || !consumerSecret || !shortcode ||
      !passkey || !callbackUrl || environment !== 'sandbox'
    ) {
      return NextResponse.json(
        { error: 'Daraja sandbox configuration is incomplete.' },
        { status: 503 },
      )
    }

    const callback = new URL(callbackUrl)
    if (callback.protocol !== 'https:') {
      return NextResponse.json(
        { error: 'The M-Pesa callback URL must use HTTPS.' },
        { status: 503 },
      )
    }

    const { data: profile, error: profileError } =
      await userClient
        .from('profiles')
        .select('account_id')
        .eq('user_id', user.id)
        .single()

    if (profileError || !profile?.account_id) {
      return NextResponse.json(
        { error: 'No business account is linked to this user.' },
        { status: 403 },
      )
    }

    const admin = supabaseAdmin()

    const { data: payment, error: insertError } = await admin
      .from('mpesa_payments')
      .insert({
        account_id: profile.account_id,
        phone_number: phone,
        amount,
        currency: 'KES',
        status: 'pending',
      })
      .select('id')
      .single()

    if (insertError || !payment) {
      console.error('Could not create payment record', insertError)
      return NextResponse.json(
        { error: 'Could not create the payment record.' },
        { status: 500 },
      )
    }

    const baseUrl = 'https://sandbox.safaricom.co.ke'

    const tokenResponse = await fetch(
      `${baseUrl}/oauth/v1/generate?grant_type=client_credentials`,
      {
        headers: {
          Authorization:
            `Basic ${Buffer.from(`${consumerKey}:${consumerSecret}`).toString('base64')}`,
        },
        cache: 'no-store',
      },
    )

    if (!tokenResponse.ok) {
      await admin.from('mpesa_payments')
        .update({ status: 'failed', result_description: 'Daraja authentication failed' })
        .eq('id', payment.id)

      console.error('Daraja token request failed', tokenResponse.status)
      return NextResponse.json(
        { error: 'Daraja authentication failed. Check the sandbox configuration.' },
        { status: 502 },
      )
    }

    const tokenData = await tokenResponse.json() as {
      access_token?: string
    }

    if (!tokenData.access_token) {
      return NextResponse.json(
        { error: 'Daraja did not return an access token.' },
        { status: 502 },
      )
    }

    const now = new Date()
    const timestamp =
      `${now.getFullYear()}` +
      `${String(now.getMonth() + 1).padStart(2, '0')}` +
      `${String(now.getDate()).padStart(2, '0')}` +
      `${String(now.getHours()).padStart(2, '0')}` +
      `${String(now.getMinutes()).padStart(2, '0')}` +
      `${String(now.getSeconds()).padStart(2, '0')}`

    const password = Buffer.from(
      `${shortcode}${passkey}${timestamp}`,
    ).toString('base64')

    const stkResponse = await fetch(
      `${baseUrl}/mpesa/stkpush/v1/processrequest`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${tokenData.access_token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          BusinessShortCode: shortcode,
          Password: password,
          Timestamp: timestamp,
          TransactionType: 'CustomerPayBillOnline',
          Amount: amount,
          PartyA: phone,
          PartyB: shortcode,
          PhoneNumber: phone,
          CallBackURL: callbackUrl,
          AccountReference: 'M-BizLipa',
          TransactionDesc: 'M-BizLipa payment',
        }),
        cache: 'no-store',
      },
    )

    const stkData = await stkResponse.json().catch(() => ({})) as {
      CheckoutRequestID?: string
      MerchantRequestID?: string
      ResponseCode?: string
      ResponseDescription?: string
      errorMessage?: string
    }

    if (
      !stkResponse.ok ||
      stkData.ResponseCode !== '0' ||
      !stkData.CheckoutRequestID
    ) {
      await admin.from('mpesa_payments')
        .update({
          status: 'failed',
          result_description:
            stkData.errorMessage ||
            stkData.ResponseDescription ||
            'STK Push request failed',
        })
        .eq('id', payment.id)

      console.error('Daraja STK request failed', stkResponse.status)
      return NextResponse.json(
        { error: 'Safaricom did not accept the STK Push request.' },
        { status: 502 },
      )
    }

    const { error: updateError } = await admin
      .from('mpesa_payments')
      .update({
        checkout_request_id: stkData.CheckoutRequestID,
        merchant_request_id: stkData.MerchantRequestID ?? null,
        status: 'processing',
      })
      .eq('id', payment.id)

    if (updateError) {
      console.error('Could not update payment record', updateError)
      return NextResponse.json(
        { error: 'The request was accepted, but the payment record needs investigation.' },
        { status: 500 },
      )
    }

    return NextResponse.json({
      message: 'STK Push request accepted. Check the phone for the payment prompt.',
      paymentId: payment.id,
      checkoutRequestId: stkData.CheckoutRequestID,
    })
  } catch (error) {
    console.error('STK Push route error', error)
    return NextResponse.json(
      { error: 'Unable to initiate the payment request.' },
      { status: 500 },
    )
  }
}
