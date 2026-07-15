/**
 * StripeDonationService — community-user donation checkout.
 *
 * Supports one-time, monthly and yearly recurring donations of ANY amount using
 * Stripe inline price_data (no pre-made Price objects needed):
 *   one-time → Checkout Session mode=payment
 *   monthly  → Checkout Session mode=subscription, recurring.interval=month
 *   yearly   → Checkout Session mode=subscription, recurring.interval=year
 *
 * The session is created ui_mode=embedded + redirect_on_completion='never' so the
 * Stripe payment UI loads inside the page and the donor never leaves the site;
 * card data is entered on Stripe's gateway iframe, never on the LWC.
 *
 * Identity is the running community user's Contact (client_reference_id + metadata).
 */
public with sharing class StripeDonationService {

    /** Prefill info for the running community user (empty for guests / no contact). */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getMyContactInfo() {
        Map<String, Object> out = new Map<String, Object>{ 'hasContact' => false };
        List<User> us = [
            SELECT ContactId, Contact.FirstName, Contact.LastName, Contact.Email, Contact.Phone,
                   Contact.MailingStreet, Contact.MailingCity, Contact.MailingState, Contact.MailingPostalCode
            FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1
        ];
        if (!us.isEmpty() && us[0].ContactId != null) {
            User u = us[0];
            out.put('hasContact', true);
            out.put('contactId', u.ContactId);
            out.put('firstName', u.Contact.FirstName);
            out.put('lastName', u.Contact.LastName);
            out.put('email', u.Contact.Email);
            out.put('phone', u.Contact.Phone);
            out.put('street', u.Contact.MailingStreet);
            out.put('city', u.Contact.MailingCity);
            out.put('state', u.Contact.MailingState);
            out.put('postalCode', u.Contact.MailingPostalCode);
        } else {
            out.put('firstName', UserInfo.getFirstName());
            out.put('lastName', UserInfo.getLastName());
            out.put('email', UserInfo.getUserEmail());
        }
        return out;
    }

    /**
     * @param frequency  'one-time' | 'month' | 'year'
     * @return JSON { success, clientSecret, publishableKey, paymentRecordId, message }
     */
    // Backwards-compatible overload (non-Aura; @AuraEnabled cannot be overloaded).
    public static String createDonationCheckout(Decimal amount, String currencyCode, String frequency,
            String name, String email, String designation) {
        return createDonationCheckout(amount, currencyCode, frequency, name, email, designation, null, null);
    }

    /**
     * @param installments  for recurring donations: total number of payments (incl. the
     *   first). e.g. 12 monthly = a year then auto-stop. Null/0 = recurs until canceled.
     * @param returnUrl     if provided, the embedded session uses redirect_on_completion
     *   'if_required' + this return_url so redirect-based methods (e.g. UPI) become
     *   available. When blank, behaviour is unchanged ('never' — in-page only, card/wallet).
     */
    @AuraEnabled
    public static String createDonationCheckout(Decimal amount, String currencyCode, String frequency,
            String name, String email, String designation, Integer installments, String returnUrl) {
        Map<String, Object> out = new Map<String, Object>{ 'success' => false };
        try {
            if (amount == null || amount <= 0) { out.put('message', 'Enter a donation amount greater than zero.'); return JSON.serialize(out); }
            StripeConfigReader.Credentials creds = StripeConfigReader.getCredentials();
            if (creds == null || String.isBlank(creds.publishableKey)
                || (String.isBlank(creds.secretKey) && String.isBlank(creds.namedCredential))) {
                out.put('message', 'Stripe is not configured.'); return JSON.serialize(out);
            }

            String contactId = resolveContactId();
            String freq = String.isBlank(frequency) ? 'one-time' : frequency.toLowerCase();
            Boolean recurring = (freq == 'month' || freq == 'year');
            String cur = String.isBlank(currencyCode) ? 'usd' : currencyCode.toLowerCase();
            Long minor = (amount * 100).setScale(0, System.RoundingMode.HALF_UP).longValue();

            String productName = recurring
                ? (freq == 'month' ? 'Monthly Donation' : 'Annual Donation')
                : 'Donation';

            Map<String, Object> priceData = new Map<String, Object>{
                'currency' => cur,
                'unit_amount' => minor,
                'product_data' => new Map<String, Object>{ 'name' => productName }
            };
            if (recurring) {
                priceData.put('recurring', new Map<String, Object>{ 'interval' => freq });
            }

            Map<String, Object> metadata = new Map<String, Object>{ 'frequency' => freq };
            if (String.isNotBlank(contactId)) metadata.put('contact_id', contactId);
            if (String.isNotBlank(designation)) metadata.put('designation', designation);
            if (String.isNotBlank(name)) metadata.put('donor_name', name);

            Map<String, Object> body = new Map<String, Object>{
                'mode' => recurring ? 'subscription' : 'payment',
                'ui_mode' => 'embedded',
                'line_items' => new List<Object>{ new Map<String, Object>{ 'price_data' => priceData, 'quantity' => 1 } },
                'metadata' => metadata,
                // India (export) accounts require the full billing name + address.
                'billing_address_collection' => 'required'
            };
            // A return_url unlocks redirect-based methods (UPI). Card/wallet still finish
            // in-page (no redirect) and fire onComplete, so the current UI is unchanged.
            // No return_url → keep the original in-page-only behaviour ('never').
            if (String.isNotBlank(returnUrl)) {
                body.put('redirect_on_completion', 'if_required');
                body.put('return_url', returnUrl);
            } else {
                body.put('redirect_on_completion', 'never');
            }
            // Attach a Customer carrying the donor's name so Stripe prefills/shows the
            // name (and email) on the checkout page — no re-entry needed.
            String customerId;
            if (String.isNotBlank(name) || String.isNotBlank(email)) {
                customerId = StripeCustomerService.findOrCreateCustomer(email, name, contactId);
            }
            if (String.isNotBlank(customerId)) {
                body.put('customer', customerId);
                body.put('customer_update', new Map<String, Object>{ 'name' => 'auto', 'address' => 'auto' });
            } else if (String.isNotBlank(email)) {
                body.put('customer_email', email);
            }
            if (String.isNotBlank(contactId)) body.put('client_reference_id', contactId);
            // Persist metadata onto the created subscription / payment intent so failed
            // attempts and lifecycle events can be linked back to this payment.
            if (recurring) {
                // Fixed number of payments → scheduled end date (cancel_at), applied by the
                // webhook once the subscription exists (Checkout can't set cancel_at directly).
                Datetime endDate = StripeSubscriptionService.endDateForCycles(freq, installments);
                if (endDate != null) metadata.put('sf_sub_cancel_at', String.valueOf(endDate.getTime() / 1000));
                body.put('subscription_data', new Map<String, Object>{ 'metadata' => metadata });
            } else {
                body.put('payment_intent_data', new Map<String, Object>{ 'metadata' => metadata });
            }

            String idem = 'donation_' + (String.isNotBlank(contactId) ? contactId : 'anon') + '_' + DateTime.now().getTime();
            StripeApiService.ApiResponse api = StripeApiService.callout('CHECKOUT_SESSION_CREATE', body, idem);

            Stripe_Payment__c p = new Stripe_Payment__c(
                Amount__c = amount,
                Currency__c = cur,
                Customer_Name__c = name,
                Customer_Email__c = email,
                Customer_Id__c = customerId,   // lets webhook link later charges/failures back here
                Product_Info__c = productName + (String.isNotBlank(designation) ? ' — ' + designation : ''),
                Payment_Type__c = recurring ? 'Recurring' : 'One-Time',
                Checkout_Mode__c = 'EMBEDDED',
                Config_Name__c = 'Donation',
                Source_Object__c = 'Contact',
                Source_Record_Id__c = contactId,
                Checkout_Session_Id__c = api.stripeId,
                Status__c = api.success ? 'Initiated' : 'Error',
                Idempotency_Key__c = idem,
                Raw_Response__c = api.rawBody != null ? api.rawBody.left(131072) : null,
                Error_Message__c = api.errorMessage
            );
            if (Schema.sObjectType.Stripe_Payment__c.isCreateable()) insert p;

            out.put('success', api.success);
            out.put('clientSecret', api.clientSecret);
            out.put('publishableKey', creds.publishableKey);
            out.put('checkoutSessionId', api.stripeId);
            out.put('paymentRecordId', p.Id);
            out.put('message', api.errorMessage);
        } catch (Exception e) {
            out.put('message', e.getMessage());
        }
        return JSON.serialize(out);
    }

    private static String resolveContactId() {
        try {
            List<User> us = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1];
            return (!us.isEmpty() && us[0].ContactId != null) ? String.valueOf(us[0].ContactId) : null;
        } catch (Exception e) { return null; }
    }
}