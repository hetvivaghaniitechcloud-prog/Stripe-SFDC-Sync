/**
 * StripeSubscriptionService — recurring lifecycle (create/update/cancel) and
 * Stripe_Subscription__c sync.
 *
 * Two creation paths:
 *   A) Checkout Session, mode=subscription  → hosted/embedded recurring checkout.
 *   B) Subscriptions API + Payment Element   → payment_behavior=default_incomplete,
 *      expand latest_invoice.payment_intent, then confirm the client_secret
 *      client-side. https://docs.stripe.com/billing/subscriptions/build-subscriptions
 */
// `without sharing`: this is trusted package bookkeeping over internal Stripe_* objects
// (mirrors StripeWebhookHandler). Guest/community-initiated actions must be able to sync
// the system-owned subscription records, which record-level sharing would otherwise block.
public without sharing class StripeSubscriptionService {

    // ── Path A: recurring Checkout Session (mode=subscription) ──
    // endDate (optional): scheduled end. Checkout's subscription_data does NOT accept
    // cancel_at, so it is carried in subscription metadata (sf_sub_cancel_at) and applied
    // by the webhook via StripeSubscriptionEndDateQueueable once the subscription exists.
    @AuraEnabled
    public static String createSubscriptionCheckout(String priceId, String mode, String customerEmail,
            String customerId, Integer trialDays, Boolean allowPromotionCodes, String sfRecordId, Datetime endDate) {
        try {
            if (String.isBlank(priceId)) return fail('priceId is required for a subscription checkout.');
            StripeConfigReader.Credentials creds = StripeConfigReader.getCredentials();
            if (creds == null || String.isBlank(creds.publishableKey)) return fail('Stripe not configured.');
            String m = String.isBlank(mode) ? 'HOSTED' : mode.toUpperCase();

            Map<String, Object> body = new Map<String, Object>{
                'mode' => 'subscription',
                'ui_mode' => (m == 'EMBEDDED') ? 'embedded' : 'hosted',
                'line_items' => new List<Object>{ new Map<String, Object>{ 'price' => priceId, 'quantity' => 1 } }
            };
            if (String.isNotBlank(customerId)) body.put('customer', customerId);
            else if (String.isNotBlank(customerEmail)) body.put('customer_email', customerEmail);
            if (allowPromotionCodes == true) body.put('allow_promotion_codes', true);
            Map<String, Object> subData = new Map<String, Object>();
            if (trialDays != null && trialDays > 0) subData.put('trial_period_days', trialDays);
            Map<String, Object> subMeta = new Map<String, Object>();
            if (endDate != null) subMeta.put('sf_sub_cancel_at', String.valueOf(endDate.getTime() / 1000));
            if (String.isNotBlank(sfRecordId)) subMeta.put('sf_record_id', sfRecordId);
            if (!subMeta.isEmpty()) subData.put('metadata', subMeta);
            if (!subData.isEmpty()) body.put('subscription_data', subData);
            if (String.isNotBlank(sfRecordId)) {
                body.put('client_reference_id', sfRecordId);
                body.put('metadata', new Map<String, Object>{ 'sf_record_id' => sfRecordId });
            }
            String orgUrl = URL.getOrgDomainUrl().toExternalForm();
            String ret = (String.isNotBlank(creds.returnUrl) ? creds.returnUrl : orgUrl + '/stripe/return')
                + '?session_id={CHECKOUT_SESSION_ID}';
            if (m == 'EMBEDDED') {
                body.put('return_url', ret);
            } else {
                body.put('success_url', ret);
                body.put('cancel_url', String.isNotBlank(creds.cancelUrl) ? creds.cancelUrl : orgUrl);
            }

            String idem = 'subco_' + (String.isNotBlank(sfRecordId) ? sfRecordId : priceId) + '_' + DateTime.now().getTime();
            StripeApiService.ApiResponse r = StripeApiService.callout('CHECKOUT_SESSION_CREATE', body, idem);
            return JSON.serialize(new Map<String, Object>{
                'success' => r.success, 'checkoutSessionId' => r.stripeId,
                'clientSecret' => r.clientSecret, 'hostedUrl' => r.hostedUrl,
                'publishableKey' => creds.publishableKey, 'message' => r.errorMessage
            });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    // ── Path B: Subscription with Payment Element ──
    // endDate (optional): if set, Stripe auto-cancels the subscription at that time
    // (the "end date" option). Null endDate => recurs until manually canceled.
    @AuraEnabled
    public static String createSubscription(String customerId, String priceId, Integer trialDays,
            String sfObject, String sfRecordId, Datetime endDate) {
        try {
            if (String.isBlank(customerId) || String.isBlank(priceId)) {
                return fail('customerId and priceId are required.');
            }
            Map<String, Object> body = new Map<String, Object>{
                'customer' => customerId,
                'items' => new List<Object>{ new Map<String, Object>{ 'price' => priceId } },
                'payment_behavior' => 'default_incomplete',
                'expand' => new List<Object>{ 'latest_invoice.payment_intent' }
            };
            if (trialDays != null && trialDays > 0) body.put('trial_period_days', trialDays);
            // Subscriptions API natively supports cancel_at (unlike Checkout).
            if (endDate != null) body.put('cancel_at', endDate.getTime() / 1000);
            if (String.isNotBlank(sfRecordId)) {
                body.put('metadata', new Map<String, Object>{ 'sf_record_id' => sfRecordId, 'sf_object' => sfObject });
            }
            String idem = 'sub_' + (String.isNotBlank(sfRecordId) ? sfRecordId : priceId) + '_' + DateTime.now().getTime();
            StripeApiService.ApiResponse r = StripeApiService.callout('SUBSCRIPTION_CREATE', body, idem);
            if (!r.success) return fail(r.errorMessage);

            String clientSecret = extractInvoicePiSecret(r.data);
            Stripe_Subscription__c sub = syncFromData(r.data, sfObject, sfRecordId, r.rawBody);

            return JSON.serialize(new Map<String, Object>{
                'success' => true, 'subscriptionId' => r.stripeId,
                'clientSecret' => clientSecret, 'recordId' => sub != null ? sub.Id : null
            });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    @AuraEnabled
    public static String cancelSubscription(String subscriptionId, Boolean atPeriodEnd) {
        try {
            if (String.isBlank(subscriptionId)) return fail('subscriptionId is required.');
            StripeApiService.ApiResponse r;
            if (atPeriodEnd == true) {
                r = StripeApiService.callout('SUBSCRIPTION_UPDATE',
                    new Map<String, String>{ 'id' => subscriptionId },
                    new Map<String, Object>{ 'cancel_at_period_end' => true }, null);
            } else {
                r = StripeApiService.callout('SUBSCRIPTION_CANCEL',
                    new Map<String, String>{ 'id' => subscriptionId }, null, null);
            }
            if (r.success) safeSync(r.data, r.rawBody);
            return JSON.serialize(new Map<String, Object>{ 'success' => r.success, 'message' => r.errorMessage });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    /**
     * Unified entry point for subscriber orgs: pass a Stripe subscription id and an
     * action; the package performs it and syncs Salesforce. Returns JSON {success,message}.
     * @param action  'pause' | 'resume' | 'cancel' | 'cancel_at_period_end'
     */
    @AuraEnabled
    public static String manageSubscription(String subscriptionId, String action) {
        if (String.isBlank(subscriptionId)) return fail('subscriptionId is required.');
        if (String.isBlank(action)) return fail('action is required.');
        switch on action.trim().toLowerCase() {
            when 'pause' { return pauseSubscription(subscriptionId); }
            when 'resume' { return resumeSubscription(subscriptionId); }
            when 'cancel' { return cancelSubscription(subscriptionId, false); }
            when 'cancel_at_period_end' { return cancelSubscription(subscriptionId, true); }
            when else { return fail('Unknown action "' + action + '". Use pause, resume, cancel, or cancel_at_period_end.'); }
        }
    }

    /** Pause payment collection (subscription keeps its Stripe status=active). */
    @AuraEnabled
    public static String pauseSubscription(String subscriptionId) {
        try {
            if (String.isBlank(subscriptionId)) return fail('subscriptionId is required.');
            StripeApiService.ApiResponse r = StripeApiService.callout('SUBSCRIPTION_UPDATE',
                new Map<String, String>{ 'id' => subscriptionId },
                new Map<String, Object>{ 'pause_collection' => new Map<String, Object>{ 'behavior' => 'void' } }, null);
            if (r.success) safeSync(r.data, r.rawBody);
            return JSON.serialize(new Map<String, Object>{ 'success' => r.success, 'message' => r.errorMessage });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    /** Resume a paused subscription (clear pause_collection). */
    @AuraEnabled
    public static String resumeSubscription(String subscriptionId) {
        try {
            if (String.isBlank(subscriptionId)) return fail('subscriptionId is required.');
            // Empty string clears pause_collection in the Stripe API.
            StripeApiService.ApiResponse r = StripeApiService.callout('SUBSCRIPTION_UPDATE',
                new Map<String, String>{ 'id' => subscriptionId },
                new Map<String, Object>{ 'pause_collection' => '' }, null);
            if (r.success) safeSync(r.data, r.rawBody);
            return JSON.serialize(new Map<String, Object>{ 'success' => r.success, 'message' => r.errorMessage });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    @AuraEnabled
    public static String updateSubscriptionPrice(String subscriptionId, String newPriceId) {
        try {
            StripeApiService.ApiResponse r = StripeApiService.callout('SUBSCRIPTION_UPDATE',
                new Map<String, String>{ 'id' => subscriptionId },
                new Map<String, Object>{
                    'items' => new List<Object>{ new Map<String, Object>{ 'price' => newPriceId } }
                }, null);
            if (r.success) safeSync(r.data, r.rawBody);
            return JSON.serialize(new Map<String, Object>{ 'success' => r.success, 'message' => r.errorMessage });
        } catch (Exception e) { return fail(e.getMessage()); }
    }

    /** Sync is best-effort: a sync failure must never mask a successful API call. */
    private static void safeSync(Map<String, Object> data, String rawJson) {
        try { syncFromData(data, null, null, rawJson); }
        catch (Exception e) { System.debug(LoggingLevel.ERROR, 'Subscription sync failed: ' + e.getMessage()); }
    }

    // ── Sync Stripe subscription JSON → Stripe_Subscription__c ──
    public static Stripe_Subscription__c syncFromData(Map<String, Object> sub, String sfObject, String sfRecordId) {
        // No raw HTTP body handy → persist a faithful re-serialization of the object.
        return syncFromData(sub, sfObject, sfRecordId, sub != null ? JSON.serialize(sub) : null);
    }

    public static Stripe_Subscription__c syncFromData(Map<String, Object> sub, String sfObject, String sfRecordId, String rawJson) {
        if (sub == null) return null;
        String subId = strOf(sub.get('id'));
        if (String.isBlank(subId)) return null;

        // Internal package object bookkeeping runs in system mode (trusted sync),
        // mirroring StripeWebhookHandler. Object-agnostic/source access uses USER_MODE.
        List<Stripe_Subscription__c> existing = [
            SELECT Id, Subscription_Id__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = :subId LIMIT 1
        ];
        Stripe_Subscription__c s = existing.isEmpty()
            ? new Stripe_Subscription__c(Subscription_Id__c = subId) : existing[0];
        s.Subscription_Id__c = subId; // ensure external id is populated so upsert updates (never fails/duplicates)
        s.Customer_Id__c = strOf(sub.get('customer'));
        s.Status__c = strOf(sub.get('status'));
        s.Cancel_At_Period_End__c = (sub.get('cancel_at_period_end') == true);
        s.Paused__c = (sub.get('pause_collection') != null);
        s.Cancel_At__c = epochToDt(sub.get('cancel_at'));
        s.Ended_At__c = epochToDt(sub.get('ended_at'));
        s.Current_Period_Start__c = epochToDt(sub.get('current_period_start'));
        s.Current_Period_End__c = epochToDt(sub.get('current_period_end'));
        s.Latest_Invoice_Id__c = invoiceId(sub.get('latest_invoice'));
        if (String.isNotBlank(sfObject)) s.Source_Object__c = sfObject;
        if (String.isNotBlank(sfRecordId)) s.Source_Record_Id__c = sfRecordId;
        if (String.isNotBlank(rawJson)) s.Raw_Response__c = rawJson.length() > 131072 ? rawJson.left(131072) : rawJson;

        Map<String, Object> items = (Map<String, Object>) sub.get('items');
        if (items != null) {
            List<Object> data = (List<Object>) items.get('data');
            if (data != null && !data.isEmpty()) {
                Map<String, Object> price = (Map<String, Object>) ((Map<String, Object>) data[0]).get('price');
                if (price != null) {
                    s.Price_Id__c = strOf(price.get('id'));
                    s.Product_Id__c = strOf(price.get('product'));
                    s.Currency__c = strOf(price.get('currency'));
                    Decimal amt = decOf(price.get('unit_amount'));
                    if (amt != null) s.Amount__c = amt / 100;
                    Map<String, Object> rec = (Map<String, Object>) price.get('recurring');
                    if (rec != null) s.Interval__c = strOf(rec.get('interval'));
                }
            }
        }
        if (Schema.sObjectType.Stripe_Subscription__c.isCreateable()) upsert s Subscription_Id__c;
        return s;
    }

    /**
     * Compute the scheduled end (cancel_at) for a fixed number of billing cycles.
     * interval = 'month' | 'year'; cycles = total number of charges (incl. the first).
     * Returns a Datetime inside the final period, so exactly `cycles` invoices are billed
     * and Stripe cancels before the next one. Returns null for open-ended (cycles<=0/null).
     * Example: monthly, 3 cycles → charges at t0, +1mo, +2mo, then cancels before +3mo.
     */
    public static Datetime endDateForCycles(String interval, Integer cycles) {
        if (cycles == null || cycles <= 0) return null;
        Datetime start = Datetime.now();
        Datetime periodStartOfLast = ('year' == interval)
            ? start.addYears(cycles - 1)
            : start.addMonths(cycles - 1);
        // land 1 day into the last period so the last renewal has already billed
        return periodStartOfLast.addDays(1);
    }

    // ── Helpers ──
    private static String extractInvoicePiSecret(Map<String, Object> sub) {
        Object inv = sub.get('latest_invoice');
        if (!(inv instanceof Map<String, Object>)) return null;
        Object pi = ((Map<String, Object>) inv).get('payment_intent');
        if (!(pi instanceof Map<String, Object>)) return null;
        return strOf(((Map<String, Object>) pi).get('client_secret'));
    }
    private static String invoiceId(Object inv) {
        if (inv instanceof String) return (String) inv;
        if (inv instanceof Map<String, Object>) return strOf(((Map<String, Object>) inv).get('id'));
        return null;
    }
    private static String strOf(Object o) { return o != null ? String.valueOf(o) : null; }
    private static Decimal decOf(Object o) { try { return o != null ? Decimal.valueOf(String.valueOf(o)) : null; } catch (Exception e) { return null; } }
    private static DateTime epochToDt(Object o) {
        if (o == null) return null;
        try { return DateTime.newInstance(Long.valueOf(String.valueOf(o)) * 1000); } catch (Exception e) { return null; }
    }
    private static String fail(String m) { return JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => m }); }
}