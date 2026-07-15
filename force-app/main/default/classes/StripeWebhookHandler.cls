/**
 * StripeWebhookHandler — receives and verifies Stripe webhook events.
 *
 * Endpoint:  /services/apexrest/stripe/webhook   (expose via a Salesforce Site
 *            so Stripe can POST to it unauthenticated; the Site guest user runs it).
 *
 * Signature verification (verified against https://docs.stripe.com/webhooks):
 *   1. Read the RAW body — never deserialize before verifying.
 *   2. Parse the Stripe-Signature header: split on ',' then '='; take t and v1.
 *   3. signedPayload = t + '.' + rawBody.
 *   4. HMAC-SHA256(signedPayload, whsec) → hex (EncodingUtil.convertToHex).
 *   5. Constant-time compare the hex against each v1 (timing-safe).
 *   6. Replay protection: reject if abs(now - t) > 300 seconds.
 *   7. Rotation: accept if ANY configured signing secret matches.
 *   8. Idempotency: key the log on Stripe event.id (globally unique); 200 on dup.
 *   9. Return 2xx fast, then route on event.type.
 *
 * DML runs in system context: this is a trusted, signature-verified gateway
 * callback (not user-entered data). User-facing classes use USER_MODE.
 *
 * @author  Stripe Connector Package
 * @version 1.0
 */
@RestResource(urlMapping='/stripe/webhook')
global without sharing class StripeWebhookHandler {

    public static final Integer TOLERANCE_SECONDS = 300;

    // Current event context (set per request) — used to stamp Payment Received rows.
    private static String currentEventId;
    private static String currentEventType;
    private static String currentPayload;

    @HttpPost
    global static void handleWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        String payload = (req != null && req.requestBody != null) ? req.requestBody.toString() : '';
        String sigHeader = getHeaderIgnoreCase(req, 'Stripe-Signature');

        try {
            // ── Verify signature BEFORE parsing the body ──
            List<String> secrets = StripeConfigReader.getWebhookSecrets();
            Long nowEpoch = DateTime.now().getTime() / 1000;
            VerifyResult vr = verifySignature(payload, sigHeader, secrets, TOLERANCE_SECONDS, nowEpoch);

            // ── Parse event (id + type) ──
            String eventId = '';
            String eventType = '';
            Map<String, Object> event;
            try {
                event = (Map<String, Object>) JSON.deserializeUntyped(payload);
                if (event.get('id') != null) eventId = String.valueOf(event.get('id'));
                if (event.get('type') != null) eventType = String.valueOf(event.get('type'));
            } catch (Exception pe) {
                event = new Map<String, Object>();
            }

            // ── Idempotency on event.id ──
            if (String.isNotBlank(eventId)) {
                List<Stripe_Webhook_Log__c> dup = [
                    SELECT Id FROM Stripe_Webhook_Log__c WHERE Event_Id__c = :eventId LIMIT 1
                ];
                if (!dup.isEmpty()) {
                    respond(res, 200, '{"status":"duplicate"}');
                    return;
                }
            }

            // ── Audit log ──
            Stripe_Webhook_Log__c log = new Stripe_Webhook_Log__c(
                Event_Id__c = String.isNotBlank(eventId) ? eventId : ('NO_ID_' + DateTime.now().getTime()),
                Event_Type__c = eventType,
                Payload__c = payload.left(131072),
                Signature_Verified__c = vr.verified,
                Source_IP__c = (req != null) ? req.remoteAddress : null,
                Processing_Status__c = vr.verified ? 'Processing' : vr.status
            );
            if (!vr.verified) log.Error_Message__c = vr.message;
            insert log;

            if (!vr.verified) {
                // Acknowledge with non-2xx so Stripe retries only for transient cases;
                // for invalid signature return 400 (Stripe will not usefully retry a bad sig).
                respond(res, 400, '{"status":"signature_verification_failed"}');
                return;
            }

            // ── Route ──
            currentEventId = eventId;
            currentEventType = eventType;
            currentPayload = payload;
            try {
                routeEvent(eventType, event, log.Id);
                log.Processing_Status__c = 'Processed';
            } catch (Exception ex) {
                log.Processing_Status__c = 'Error';
                log.Error_Message__c = ex.getMessage() + '\n' + ex.getStackTraceString();
            }
            update log;

            respond(res, 200, '{"status":"ok"}');

        } catch (Exception ex) {
            try {
                insert new Stripe_Webhook_Log__c(
                    Event_Id__c = 'ERR_' + DateTime.now().getTime(),
                    Event_Type__c = 'error',
                    Payload__c = payload.left(131072),
                    Signature_Verified__c = false,
                    Processing_Status__c = 'Error',
                    Error_Message__c = ex.getMessage()
                );
            } catch (Exception ignore) {}
            respond(res, 200, '{"status":"error"}');
        }
    }

    // ═══════════════════ Signature verification ═══════════════════

    public class VerifyResult {
        public Boolean verified = false;
        public String status = 'Rejected - Invalid Signature';
        public String message;
    }

    /**
     * Verifies a Stripe webhook signature. Exposed (TestVisible) so tests can
     * sign a fixture body with a known secret and assert accept/reject paths.
     */
    @TestVisible
    public static VerifyResult verifySignature(String payload, String sigHeader,
            List<String> secrets, Integer toleranceSeconds, Long nowEpoch) {
        VerifyResult r = new VerifyResult();
        if (String.isBlank(sigHeader)) { r.message = 'Missing Stripe-Signature header.'; return r; }
        if (secrets == null || secrets.isEmpty()) { r.message = 'No webhook signing secret configured.'; return r; }

        // Parse header: t=...,v1=...,v1=...,v0=...
        String t = null;
        List<String> v1s = new List<String>();
        for (String element : sigHeader.split(',')) {
            List<String> kv = element.trim().split('=', 2);
            if (kv.size() != 2) continue;
            String prefix = kv[0].trim();
            String value = kv[1].trim();
            if (prefix == 't') t = value;
            else if (prefix == 'v1') v1s.add(value);
        }
        if (String.isBlank(t) || v1s.isEmpty()) { r.message = 'Malformed Stripe-Signature header.'; return r; }

        // Replay protection
        Long ts;
        try { ts = Long.valueOf(t); } catch (Exception e) { r.message = 'Invalid timestamp.'; return r; }
        if (toleranceSeconds != null && toleranceSeconds > 0) {
            Long diff = Math.abs(nowEpoch - ts);
            if (diff > toleranceSeconds) {
                r.status = 'Rejected - Stale';
                r.message = 'Timestamp outside tolerance (' + diff + 's > ' + toleranceSeconds + 's).';
                return r;
            }
        }

        // Compute expected signature for each accepted secret (rotation-aware)
        String signedPayload = t + '.' + payload;
        for (String secret : secrets) {
            if (String.isBlank(secret)) continue;
            Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(signedPayload), Blob.valueOf(secret));
            String expected = EncodingUtil.convertToHex(mac);
            for (String v1 : v1s) {
                if (secureEquals(expected, v1)) {
                    r.verified = true;
                    r.status = 'Processing';
                    return r;
                }
            }
        }
        r.message = 'No signing secret produced a matching signature.';
        return r;
    }

    /** Timing-safe string comparison (XOR over full length; no early exit). */
    @TestVisible
    private static Boolean secureEquals(String a, String b) {
        if (a == null || b == null) return false;
        Integer diff = a.length() ^ b.length();
        Integer len = Math.min(a.length(), b.length());
        for (Integer i = 0; i < len; i++) {
            diff |= (a.charAt(i) ^ b.charAt(i));
        }
        return diff == 0;
    }

    // ═══════════════════ Event routing ═══════════════════

    /** Re-route a previously-verified, stored event payload (used by StripeWebhookRetry). */
    public static void reprocess(String payload, Id logId) {
        Map<String, Object> event = (Map<String, Object>) JSON.deserializeUntyped(payload);
        String eventType = event.get('type') != null ? String.valueOf(event.get('type')) : '';
        currentEventId = strOf(event.get('id'));
        currentEventType = eventType;
        currentPayload = payload;
        routeEvent(eventType, event, logId);
    }

    private static void routeEvent(String eventType, Map<String, Object> event, Id logId) {
        Map<String, Object> obj = getEventObject(event);
        if (obj == null) return;

        switch on eventType {
            // ── Checkout Session ──
            when 'checkout.session.completed', 'checkout.session.async_payment_succeeded' { handleCheckoutCompleted(obj, logId); }
            when 'checkout.session.expired' { handleCheckoutExpired(obj, logId); }
            when 'checkout.session.async_payment_failed' { handleCheckoutFailed(obj, logId); }

            // ── PaymentIntent (full lifecycle) ──
            when 'payment_intent.succeeded' { updatePaymentByIntent(obj, 'Completed', 'Succeeded', logId); }
            when 'payment_intent.payment_failed' { updatePaymentByIntent(obj, 'Failed', 'Failed', logId); }
            when 'payment_intent.canceled' { updatePaymentByIntent(obj, 'Cancelled', 'Cancelled', logId); }
            when 'payment_intent.processing' { updatePaymentByIntent(obj, 'Processing', 'Processing', logId); }
            when 'payment_intent.requires_action' { updatePaymentByIntent(obj, 'Requires Action', 'Requires Action', logId); }

            // ── Charge (attempt-level audit) ──
            when 'charge.succeeded', 'charge.captured' { handleCharge(obj, 'Succeeded', logId); }
            when 'charge.failed' { handleCharge(obj, 'Failed', logId); }
            when 'charge.pending' { handleCharge(obj, 'Pending', logId); }
            when 'charge.expired' { handleCharge(obj, 'Cancelled', logId); }
            when 'charge.refunded' { handleChargeRefunded(obj, logId); }

            // ── Disputes ──
            when 'charge.dispute.created', 'charge.dispute.funds_withdrawn' { handleDispute(obj, logId); }
            when 'charge.dispute.closed', 'charge.dispute.funds_reinstated' { handleDisputeClosed(obj, logId); }

            // ── Refunds ──
            when 'refund.created', 'refund.updated', 'refund.failed', 'charge.refund.updated' { handleRefundEvent(obj, logId); }

            // ── Invoices (recurring billing) ──
            // invoice.paid records the renewal row; invoice.payment_succeeded is the same
            // invoice payment from a second event — mark active only, so we get ONE row/cycle.
            when 'invoice.paid' { handleInvoicePaid(obj, logId); }
            when 'invoice.payment_succeeded' { handleInvoicePaidActiveOnly(obj); }
            when 'invoice.payment_failed' { handleInvoiceStatus(obj, 'past_due'); }
            when 'invoice.payment_action_required' { handleInvoiceStatus(obj, 'past_due'); }
            when 'invoice.marked_uncollectible' { handleInvoiceStatus(obj, 'unpaid'); }
            when 'invoice.voided' { handleInvoiceStatus(obj, 'canceled'); }

            // ── Subscriptions (full lifecycle) ──
            when 'customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted',
                 'customer.subscription.paused', 'customer.subscription.resumed',
                 'customer.subscription.pending_update_applied', 'customer.subscription.pending_update_expired',
                 'customer.subscription.trial_will_end' { syncSubscription(obj); }

            // ── SetupIntent (save card / mandate) ──
            when 'setup_intent.succeeded' { handleSetupIntent(obj, 'Completed', logId); }
            when 'setup_intent.setup_failed' { handleSetupIntent(obj, 'Failed', logId); }

            when else { /* every event is still logged to Stripe_Webhook_Log__c; just no state change */ }
        }
    }

    @SuppressWarnings('PMD.ApexCRUDViolation') // trusted, signature-verified gateway callback
    private static void handleCheckoutCompleted(Map<String, Object> session, Id logId) {
        String sessionId = strOf(session.get('id'));
        String clientRef = strOf(session.get('client_reference_id'));
        String paymentIntentId = strOf(session.get('payment_intent'));
        String subscriptionId = strOf(session.get('subscription'));
        String paymentStatus = strOf(session.get('payment_status'));
        String customerId = strOf(session.get('customer'));

        List<Stripe_Payment__c> pays = [
            SELECT Id, Status__c FROM Stripe_Payment__c
            WHERE Checkout_Session_Id__c = :sessionId LIMIT 1
        ];
        Stripe_Payment__c p = pays.isEmpty() ? null : pays[0];
        if (p == null && String.isNotBlank(clientRef)) {
            List<Stripe_Payment__c> byRef = [
                SELECT Id, Status__c FROM Stripe_Payment__c
                WHERE Source_Record_Id__c = :clientRef
                  AND Checkout_Session_Id__c = null
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            p = byRef.isEmpty() ? null : byRef[0];
        }
        if (p == null) return;

        p.Status__c = (paymentStatus == 'paid' || paymentStatus == 'no_payment_required') ? 'Completed' : 'Pending';
        p.Stripe_Payment_Status__c = paymentStatus;
        p.Checkout_Session_Id__c = sessionId;
        if (String.isNotBlank(paymentIntentId)) p.Payment_Intent_Id__c = paymentIntentId;
        if (String.isNotBlank(subscriptionId)) p.Subscription_Id__c = subscriptionId;
        if (String.isNotBlank(customerId)) p.Customer_Id__c = customerId;
        p.Signature_Verified__c = true;
        p.Last_Event_Type__c = 'checkout.session.completed';
        update p;

        // If this checkout created a subscription, stamp the first charge onto it too
        // (best-effort — the subscription record may arrive via its own webhook shortly after).
        if (String.isNotBlank(subscriptionId)) {
            pendingSubStripeId = subscriptionId;   // link even if the sub record isn't synced yet
            Stripe_Subscription__c sub = subById(subscriptionId);
            if (sub != null) {
                pendingSubRecId = sub.Id;
                if (sub.Payment__c == null) { sub.Payment__c = p.Id; update sub; }
            }
        }

        // For a SUBSCRIPTION checkout, the first payment is also delivered as invoice.paid,
        // which records the Payment Received row. Skip it here to avoid double-counting the
        // first cycle. One-time (payment mode) checkouts have no invoice, so record it here.
        if (String.isBlank(subscriptionId)) {
            String rcvStatus = (paymentStatus == 'paid' || paymentStatus == 'no_payment_required') ? 'Succeeded' : 'Pending';
            createReceived(p.Id, rcvStatus, decOf(session.get('amount_total')), strOf(session.get('currency')),
                paymentIntentId, null, null, null);
        }

        linkLog(logId, p.Id);
        if (p.Status__c == 'Completed') executePostPaymentActions(p.Id);
    }

    /** Session abandoned / expired (donor closed checkout without paying). */
    private static void handleCheckoutExpired(Map<String, Object> session, Id logId) {
        handleCheckoutTerminal(session, logId, 'Cancelled', 'checkout.session.expired');
    }
    /** Async payment method (e.g. bank redirect) failed after checkout. */
    private static void handleCheckoutFailed(Map<String, Object> session, Id logId) {
        handleCheckoutTerminal(session, logId, 'Failed', 'checkout.session.async_payment_failed');
    }
    private static void handleCheckoutTerminal(Map<String, Object> session, Id logId, String newStatus, String evt) {
        String sessionId = strOf(session.get('id'));
        String clientRef = strOf(session.get('client_reference_id'));
        List<Stripe_Payment__c> pays = [
            SELECT Id, Status__c FROM Stripe_Payment__c WHERE Checkout_Session_Id__c = :sessionId LIMIT 1
        ];
        if (pays.isEmpty() && String.isNotBlank(clientRef)) {
            pays = [SELECT Id, Status__c FROM Stripe_Payment__c
                    WHERE Source_Record_Id__c = :clientRef AND Checkout_Session_Id__c = :sessionId LIMIT 1];
        }
        Id payId = pays.isEmpty() ? null : pays[0].Id;
        if (!pays.isEmpty()) {
            Stripe_Payment__c p = pays[0];
            if (p.Status__c != 'Completed') {   // never overwrite a paid record
                p.Status__c = newStatus;
                p.Last_Event_Type__c = evt;
                p.Signature_Verified__c = true;
                update p;
            }
        }
        createReceived(payId, newStatus == 'Cancelled' ? 'Cancelled' : 'Failed',
            decOf(session.get('amount_total')), strOf(session.get('currency')),
            strOf(session.get('payment_intent')), null, null, null);
        if (payId != null) linkLog(logId, payId);
    }

    private static void updatePaymentByIntent(Map<String, Object> intent, String paymentStatus, String receivedStatus, Id logId) {
        String intentId = strOf(intent.get('id'));
        if (String.isBlank(intentId)) return;
        List<Stripe_Payment__c> pays = [
            SELECT Id, Status__c, Source_Object__c, Source_Record_Id__c, Config_Name__c, Payment_Intent_Id__c
            FROM Stripe_Payment__c WHERE Payment_Intent_Id__c = :intentId LIMIT 1
        ];
        Boolean linkNow = false;
        if (pays.isEmpty()) {
            // Checkout payments have no PI id until completion — link via metadata.sf_record_id
            // so a FAILED attempt (which fires before completion) still attaches to the payment.
            String sfRec = metaValue(intent, 'sf_record_id');
            if (String.isNotBlank(sfRec)) {
                pays = [
                    SELECT Id, Status__c, Source_Object__c, Source_Record_Id__c, Config_Name__c, Payment_Intent_Id__c
                    FROM Stripe_Payment__c
                    WHERE Source_Record_Id__c = :sfRec AND Payment_Intent_Id__c = null
                    ORDER BY CreatedDate DESC LIMIT 1
                ];
                linkNow = !pays.isEmpty();
            }
        }
        // Customer fallback is ONLY for failures. On success the session-based
        // checkout.session.completed already links the correct payment, so never let this
        // heuristic mark an unrelated open payment (e.g. an abandoned one-time the donor
        // switched away from) as Completed.
        if (pays.isEmpty() && paymentStatus != 'Completed') {
            // Last resort (e.g. subscription/donation checkout, where the PI lives on the
            // invoice with no sf metadata): attach to the customer's most recent open payment.
            String custId = strOf(intent.get('customer'));
            if (String.isNotBlank(custId)) {
                pays = [
                    SELECT Id, Status__c, Source_Object__c, Source_Record_Id__c, Config_Name__c, Payment_Intent_Id__c
                    FROM Stripe_Payment__c
                    WHERE Customer_Id__c = :custId AND Payment_Intent_Id__c = null
                      AND Status__c IN ('Initiated', 'Pending', 'Processing')
                    ORDER BY CreatedDate DESC LIMIT 1
                ];
                linkNow = !pays.isEmpty();
            }
        }
        Id payId = pays.isEmpty() ? null : pays[0].Id;
        String chargeId = (intent.get('latest_charge') instanceof String) ? (String) intent.get('latest_charge') : null;

        if (!pays.isEmpty()) {
            Stripe_Payment__c p = pays[0];
            // Do not overwrite a Completed payment with a later non-completed state.
            if (!(p.Status__c == 'Completed' && paymentStatus != 'Completed')) p.Status__c = paymentStatus;
            p.Stripe_Payment_Status__c = strOf(intent.get('status'));
            p.Signature_Verified__c = true;
            p.Last_Event_Type__c = currentEventType;
            if (chargeId != null) p.Charge_Id__c = chargeId;
            if (linkNow) p.Payment_Intent_Id__c = intentId;   // remember it for future events
            // Store the decline/failure reason on the payment record itself.
            String failMsg = extractFailure(intent);
            if ((receivedStatus == 'Failed' || paymentStatus == 'Failed') && String.isNotBlank(failMsg)) {
                p.Error_Message__c = failMsg;
            }
            update p;
        }

        // Always record the attempt — linked when found, else unlinked (never lose an event).
        createReceived(payId, receivedStatus, decOf(intent.get('amount')), strOf(intent.get('currency')),
            intentId, chargeId, null, extractFailure(intent));

        if (payId != null) {
            linkLog(logId, payId);
            if (paymentStatus == 'Completed') executePostPaymentActions(payId);
        }
    }

    private static String metaValue(Map<String, Object> obj, String key) {
        Object md = obj.get('metadata');
        return (md instanceof Map<String, Object>) ? strOf(((Map<String, Object>) md).get(key)) : null;
    }

    /** charge.succeeded / charge.failed — logged as a received row (attempt-level audit). */
    private static void handleCharge(Map<String, Object> charge, String status, Id logId) {
        String intentId = strOf(charge.get('payment_intent'));
        String chargeId = strOf(charge.get('id'));
        List<Stripe_Payment__c> pays = [
            SELECT Id FROM Stripe_Payment__c
            WHERE Payment_Intent_Id__c = :intentId OR Charge_Id__c = :chargeId LIMIT 1
        ];
        Id payId = pays.isEmpty() ? null : pays[0].Id;
        Map<String, Object> methodDetails = (Map<String, Object>) charge.get('payment_method_details');
        String method = methodDetails != null ? strOf(methodDetails.get('type')) : null;
        createReceived(payId, status, decOf(charge.get('amount')), strOf(charge.get('currency')),
            intentId, chargeId, method, strOf(charge.get('failure_message')));
        if (payId != null) linkLog(logId, payId);
    }

    private static void handleChargeRefunded(Map<String, Object> charge, Id logId) {
        String chargeId = strOf(charge.get('id'));
        String paymentIntentId = strOf(charge.get('payment_intent'));
        Decimal refunded = decOf(charge.get('amount_refunded'));
        Boolean fullyRefunded = (charge.get('refunded') == true);

        List<Stripe_Payment__c> pays = [
            SELECT Id, Amount__c, Refunded_Amount__c FROM Stripe_Payment__c
            WHERE Payment_Intent_Id__c = :paymentIntentId OR Charge_Id__c = :chargeId LIMIT 1
        ];
        if (pays.isEmpty()) return;
        Stripe_Payment__c p = pays[0];
        // Stripe amounts are in the smallest currency unit (e.g. cents)
        p.Refunded_Amount__c = (refunded != null) ? refunded / 100 : p.Refunded_Amount__c;
        p.Status__c = fullyRefunded ? 'Refunded' : 'Partial Refunded';
        p.Last_Event_Type__c = 'charge.refunded';
        update p;

        // negative amount marks the refund in the received audit trail
        Decimal refundMinor = (refunded != null) ? (refunded * -1) : null;
        createReceived(p.Id, fullyRefunded ? 'Refunded' : 'Partial Refunded', refundMinor,
            strOf(charge.get('currency')), paymentIntentId, chargeId, null, null);
        linkLog(logId, p.Id);
    }

    // ═══════════════════ Payment Received audit ═══════════════════

    /** Create one Stripe_Payment_Received__c per event (succeeded/failed/cancelled/refunded/retry).
     *  amountMinor is in Stripe's smallest unit; stored in major units. */
    // Subscription to stamp on the next received row (set by subscription-related handlers
    // just before calling createReceived; consumed and cleared once). We keep both the SF
    // record id (when the record exists) and the Stripe id (always, so a row created before
    // the subscription record exists can still be linked by backfill).
    private static Id pendingSubRecId;
    private static String pendingSubStripeId;

    @TestVisible
    private static void createReceived(Id paymentId, String status, Decimal amountMinor, String currencyCode,
            String paymentIntentId, String chargeId, String method, String failureMsg) {
        Id subRec = pendingSubRecId;
        String subStripeId = pendingSubStripeId;
        pendingSubRecId = null;   // consume so it never leaks to a later row in the same transaction
        pendingSubStripeId = null;
        try {
            if (String.isBlank(currentEventId)) return;
            // idempotent: one received row per event id
            if (![SELECT Id FROM Stripe_Payment_Received__c WHERE Event_Id__c = :currentEventId LIMIT 1].isEmpty()) return;
            insert new Stripe_Payment_Received__c(
                Payment__c = paymentId,
                Subscription__c = subRec,
                Subscription_Id__c = subStripeId,
                Event_Id__c = currentEventId,
                Event_Type__c = currentEventType,
                Status__c = status,
                Amount_Received__c = amountMinor != null ? (amountMinor / 100) : null,
                Currency__c = currencyCode,
                Payment_Intent_Id__c = paymentIntentId,
                Charge_Id__c = chargeId,
                Payment_Method__c = method,
                Failure_Message__c = failureMsg,
                Signature_Verified__c = true,
                Received_Date__c = System.now(),
                Raw_Payload__c = currentPayload != null ? currentPayload.left(131072) : null
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'createReceived failed: ' + e.getMessage());
        }
    }

    private static String extractFailure(Map<String, Object> intent) {
        Object err = intent.get('last_payment_error');
        if (err instanceof Map<String, Object>) return strOf(((Map<String, Object>) err).get('message'));
        return null;
    }

    // ── Invoices (recurring) ──

    /** The subscription id on an invoice. Newer Stripe API versions removed the top-level
     *  `subscription` field and moved it to parent.subscription_details.subscription. */
    private static String invoiceSubscriptionId(Map<String, Object> invoice) {
        String subId = strOf(invoice.get('subscription'));
        if (String.isNotBlank(subId)) return subId;
        Object parent = invoice.get('parent');
        if (parent instanceof Map<String, Object>) {
            Object sd = ((Map<String, Object>) parent).get('subscription_details');
            if (sd instanceof Map<String, Object>) return strOf(((Map<String, Object>) sd).get('subscription'));
        }
        return null;
    }

    /** invoice.paid / invoice.payment_succeeded — renewal succeeded. Marks the subscription
     *  active, stamps the latest invoice, and records a renewal Payment Received row. */
    private static void handleInvoicePaid(Map<String, Object> invoice, Id logId) {
        String subId = invoiceSubscriptionId(invoice);
        pendingSubStripeId = subId;   // always stamp the Stripe id so backfill can link it later
        // Link the renewal to the payment that created this subscription, if any.
        Id payId = paymentBySubscription(subId);
        Stripe_Subscription__c s = subById(subId);
        if (s != null) {
            s.Latest_Invoice_Id__c = strOf(invoice.get('id'));
            if (s.Status__c != 'canceled') s.Status__c = 'active';
            if (payId != null && s.Payment__c == null) s.Payment__c = payId;  // link sub → originating payment
            update s;
            pendingSubRecId = s.Id;   // stamp the received row with this subscription
        }
        // Prefer amount_paid; fall back to total/amount_due (e.g. out-of-band-paid invoices
        // report amount_paid = 0 even though the invoice total is the real amount).
        Decimal amt = decOf(invoice.get('amount_paid'));
        if (amt == null || amt == 0) amt = decOf(invoice.get('total'));
        if (amt == null || amt == 0) amt = decOf(invoice.get('amount_due'));
        createReceived(payId, 'Succeeded', amt, strOf(invoice.get('currency')),
            strOf(invoice.get('payment_intent')), strOf(invoice.get('charge')), null, null);
        if (payId != null) linkLog(logId, payId);
    }

    /** invoice.payment_succeeded — same renewal as invoice.paid; just keep the sub active
     *  (no second received row). If invoice.paid never recorded one, fall back to it. */
    private static void handleInvoicePaidActiveOnly(Map<String, Object> invoice) {
        String subId = invoiceSubscriptionId(invoice);
        Stripe_Subscription__c s = subById(subId);
        if (s == null) return;
        s.Latest_Invoice_Id__c = strOf(invoice.get('id'));
        if (s.Status__c != 'canceled') s.Status__c = 'active';
        update s;
    }

    /** invoice.payment_failed / action_required / voided / uncollectible → set subscription status. */
    private static void handleInvoiceStatus(Map<String, Object> invoice, String status) {
        String subId = invoiceSubscriptionId(invoice);
        Stripe_Subscription__c s = subById(subId);
        if (s == null) return;
        s.Latest_Invoice_Id__c = strOf(invoice.get('id'));
        s.Status__c = status;
        update s;
    }

    private static Stripe_Subscription__c subById(String subId) {
        if (String.isBlank(subId)) return null;
        List<Stripe_Subscription__c> subs = [
            SELECT Id, Status__c, Latest_Invoice_Id__c, Payment__c FROM Stripe_Subscription__c
            WHERE Subscription_Id__c = :subId LIMIT 1
        ];
        return subs.isEmpty() ? null : subs[0];
    }
    private static Id paymentBySubscription(String subId) {
        if (String.isBlank(subId)) return null;
        List<Stripe_Payment__c> pays = [SELECT Id FROM Stripe_Payment__c WHERE Subscription_Id__c = :subId ORDER BY CreatedDate DESC LIMIT 1];
        return pays.isEmpty() ? null : pays[0].Id;
    }

    // ── Disputes ──

    /** charge.dispute.created — a chargeback was opened. */
    private static void handleDispute(Map<String, Object> dispute, Id logId) {
        Id payId = paymentByChargeOrIntent(strOf(dispute.get('charge')), strOf(dispute.get('payment_intent')));
        if (payId != null) {
            update new Stripe_Payment__c(Id = payId, Status__c = 'Disputed', Last_Event_Type__c = currentEventType);
            linkLog(logId, payId);
        }
        createReceived(payId, 'Disputed', decOf(dispute.get('amount')), strOf(dispute.get('currency')),
            strOf(dispute.get('payment_intent')), strOf(dispute.get('charge')), null, strOf(dispute.get('reason')));
    }

    /** charge.dispute.closed — record the outcome (won / lost / warning_closed). */
    private static void handleDisputeClosed(Map<String, Object> dispute, Id logId) {
        Id payId = paymentByChargeOrIntent(strOf(dispute.get('charge')), strOf(dispute.get('payment_intent')));
        String outcome = strOf(dispute.get('status'));   // won | lost | warning_closed
        if (payId != null && outcome == 'lost') {
            update new Stripe_Payment__c(Id = payId, Status__c = 'Refunded', Last_Event_Type__c = currentEventType);
        }
        createReceived(payId, 'Disputed', decOf(dispute.get('amount')), strOf(dispute.get('currency')),
            strOf(dispute.get('payment_intent')), strOf(dispute.get('charge')), null, 'Dispute ' + outcome);
        if (payId != null) linkLog(logId, payId);
    }

    // ── Refunds ──

    /** refund.created / updated / failed — record the refund attempt + status. */
    private static void handleRefundEvent(Map<String, Object> refund, Id logId) {
        Id payId = paymentByChargeOrIntent(strOf(refund.get('charge')), strOf(refund.get('payment_intent')));
        String st = strOf(refund.get('status'));   // succeeded | pending | failed | canceled
        String mapped = (st == 'failed') ? 'Failed' : (st == 'succeeded' ? 'Refunded' : 'Pending');
        Decimal amt = decOf(refund.get('amount'));
        createReceived(payId, mapped, amt != null ? amt * -1 : null, strOf(refund.get('currency')),
            strOf(refund.get('payment_intent')), strOf(refund.get('charge')), null,
            strOf(refund.get('failure_reason')));
        if (payId != null) linkLog(logId, payId);
    }

    // ── SetupIntent (save card / mandate) ──

    private static void handleSetupIntent(Map<String, Object> si, String status, Id logId) {
        String siId = strOf(si.get('id'));
        List<Stripe_Payment__c> pays = [SELECT Id FROM Stripe_Payment__c WHERE Setup_Intent_Id__c = :siId LIMIT 1];
        Id payId = pays.isEmpty() ? null : pays[0].Id;
        if (payId != null) {
            update new Stripe_Payment__c(Id = payId, Status__c = status, Last_Event_Type__c = currentEventType);
            linkLog(logId, payId);
        }
        createReceived(payId, status == 'Completed' ? 'Succeeded' : 'Failed', null, null,
            null, null, null, strOf(si.get('cancellation_reason')));
    }

    private static Id paymentByChargeOrIntent(String chargeId, String intentId) {
        if (String.isBlank(chargeId) && String.isBlank(intentId)) return null;
        List<Stripe_Payment__c> pays = [
            SELECT Id FROM Stripe_Payment__c
            WHERE Charge_Id__c = :chargeId OR Payment_Intent_Id__c = :intentId LIMIT 1
        ];
        return pays.isEmpty() ? null : pays[0].Id;
    }

    private static void syncSubscription(Map<String, Object> sub) {
        String subId = strOf(sub.get('id'));
        if (String.isBlank(subId)) return;
        List<Stripe_Subscription__c> existing = [
            SELECT Id, Subscription_Id__c, Status__c, Source_Object__c, Source_Record_Id__c, Payment__c
            FROM Stripe_Subscription__c WHERE Subscription_Id__c = :subId LIMIT 1
        ];
        String incoming = strOf(sub.get('status'));

        // Out-of-order delivery guard: Stripe does not guarantee event order, so a late
        // 'created' (incomplete) event can arrive after 'active'. 'incomplete' is only an
        // initial state — never regress an already-advanced record back to it.
        if (!existing.isEmpty() && (incoming == 'incomplete' || incoming == 'incomplete_expired')) {
            String cur = existing[0].Status__c;
            if (cur != null && cur != 'incomplete' && cur != 'incomplete_expired') return;
        }

        Stripe_Subscription__c s = existing.isEmpty()
            ? new Stripe_Subscription__c(Subscription_Id__c = subId)
            : existing[0];
        s.Subscription_Id__c = subId; // ensure external id is populated so upsert updates (never duplicates)
        s.Customer_Id__c = strOf(sub.get('customer'));
        s.Status__c = incoming;
        s.Cancel_At_Period_End__c = (sub.get('cancel_at_period_end') == true);
        s.Paused__c = (sub.get('pause_collection') != null);
        s.Cancel_At__c = epochToDt(sub.get('cancel_at'));
        s.Ended_At__c = epochToDt(sub.get('ended_at'));
        s.Latest_Invoice_Id__c = strOf(sub.get('latest_invoice'));
        // Link to the donor's Contact (from metadata) so the community portal can list
        // "my subscriptions". Only set when known; never blank an existing link.
        String metaContact = metaValue(sub, 'contact_id');
        if (String.isBlank(metaContact)) metaContact = metaValue(sub, 'sf_record_id');
        if (String.isNotBlank(metaContact) && String.isBlank(s.Source_Record_Id__c)) {
            s.Source_Record_Id__c = metaContact;
            if (String.isBlank(s.Source_Object__c)) s.Source_Object__c = 'Contact';
        }
        String subRaw = JSON.serialize(sub);
        s.Raw_Response__c = subRaw.length() > 131072 ? subRaw.left(131072) : subRaw;

        // Period + price. Newer Stripe API versions moved current_period_* onto the item,
        // so read the subscription top-level first, then fall back to the first item.
        Object pStart = sub.get('current_period_start');
        Object pEnd = sub.get('current_period_end');
        Map<String, Object> items = (Map<String, Object>) sub.get('items');
        Map<String, Object> item0;
        if (items != null) {
            List<Object> data = (List<Object>) items.get('data');
            if (data != null && !data.isEmpty()) item0 = (Map<String, Object>) data[0];
        }
        if (item0 != null) {
            if (pStart == null) pStart = item0.get('current_period_start');
            if (pEnd == null) pEnd = item0.get('current_period_end');
            Map<String, Object> price = (Map<String, Object>) item0.get('price');
            if (price != null) {
                s.Price_Id__c = strOf(price.get('id'));
                s.Product_Id__c = strOf(price.get('product'));
                s.Currency__c = strOf(price.get('currency'));
                Decimal amt = decOf(price.get('unit_amount'));
                if (amt != null) s.Amount__c = amt / 100;
                Map<String, Object> recurring = (Map<String, Object>) price.get('recurring');
                if (recurring != null) s.Interval__c = strOf(recurring.get('interval'));
            }
        }
        s.Current_Period_Start__c = epochToDt(pStart);
        s.Current_Period_End__c = epochToDt(pEnd);
        try {
            upsert s Subscription_Id__c;
        } catch (DmlException de) {
            // Race: Stripe delivers subscription.created and .updated in the same instant, so
            // two transactions both find "no existing record" and both try to insert → one wins,
            // the other hits the unique constraint. Re-fetch the winner and update it instead
            // (re-applying the regression guard so a late 'incomplete' can't undo 'active').
            if (de.getMessage() == null || !de.getMessage().contains('DUPLICATE_VALUE')) throw de;
            List<Stripe_Subscription__c> won = [SELECT Id, Status__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = :subId LIMIT 1];
            if (won.isEmpty()) throw de;
            String cur = won[0].Status__c;
            if ((incoming == 'incomplete' || incoming == 'incomplete_expired')
                && cur != null && cur != 'incomplete' && cur != 'incomplete_expired') {
                return;   // don't regress the winner
            }
            s.Id = won[0].Id;
            update s;
        }

        // Pull this subscription's payment + received rows together (they may have been
        // created before this record existed, e.g. checkout.session.completed arriving
        // before customer.subscription.created).
        backfillSubscriptionLinks(s.Id, subId, s.Payment__c);

        // Apply a scheduled end date carried in metadata (sf_sub_cancel_at) for
        // Checkout-created subscriptions — Checkout can't set cancel_at at creation.
        // Only when Stripe hasn't already recorded one and the sub is billing.
        if (sub.get('cancel_at') == null) {
            String cancelAtMeta = metaValue(sub, 'sf_sub_cancel_at');
            String status = strOf(sub.get('status'));
            if (String.isNotBlank(cancelAtMeta) && (status == 'active' || status == 'trialing')) {
                try {
                    Long cancelAtEpoch = Long.valueOf(cancelAtMeta);
                    System.enqueueJob(new StripeSubscriptionEndDateQueueable(subId, cancelAtEpoch));
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, 'Could not schedule end date: ' + e.getMessage());
                }
            }
        }
    }

    /** Link a subscription to its originating payment and pull its received rows into the
     *  subscription's related list — covers events that arrived before the sub existed. */
    private static void backfillSubscriptionLinks(Id subRecId, String subId, Id currentPaymentLink) {
        if (subRecId == null || String.isBlank(subId)) return;
        Map<Id, Stripe_Payment_Received__c> orphans = new Map<Id, Stripe_Payment_Received__c>();
        // (a) received rows stamped with this Stripe subscription id (renewals/first charge
        //     that arrived before the subscription record existed — incl. rows with no payment).
        for (Stripe_Payment_Received__c r : [
            SELECT Id FROM Stripe_Payment_Received__c
            WHERE Subscription_Id__c = :subId AND Subscription__c = null
        ]) orphans.put(r.Id, r);
        // (b) received rows that belong to a payment of this subscription.
        List<Stripe_Payment__c> pays = [
            SELECT Id FROM Stripe_Payment__c WHERE Subscription_Id__c = :subId ORDER BY CreatedDate ASC
        ];
        if (!pays.isEmpty()) {
            if (currentPaymentLink == null) {
                update new Stripe_Subscription__c(Id = subRecId, Payment__c = pays[0].Id);
            }
            Set<Id> payIds = new Set<Id>();
            for (Stripe_Payment__c p : pays) payIds.add(p.Id);
            for (Stripe_Payment_Received__c r : [
                SELECT Id FROM Stripe_Payment_Received__c WHERE Payment__c IN :payIds AND Subscription__c = null
            ]) orphans.put(r.Id, r);
        }
        for (Stripe_Payment_Received__c r : orphans.values()) r.Subscription__c = subRecId;
        if (!orphans.isEmpty()) update orphans.values();
    }

    // ═══════════════════ Post-payment actions ═══════════════════

    @TestVisible
    private static void executePostPaymentActions(Id paymentId) {
        try {
            List<Stripe_Payment__c> pays = [
                SELECT Id, Amount__c, Config_Name__c, Source_Object__c, Source_Record_Id__c
                FROM Stripe_Payment__c WHERE Id = :paymentId LIMIT 1
            ];
            if (pays.isEmpty()) return;
            Stripe_Payment__c payment = pays[0];
            if (String.isBlank(payment.Config_Name__c) || String.isBlank(payment.Source_Object__c)
                || String.isBlank(payment.Source_Record_Id__c)) return;

            StripeConfigReader.PaymentConfig config =
                StripeConfigReader.getConfig(payment.Config_Name__c, payment.Source_Object__c);
            if (config == null) return;

            if (String.isNotBlank(config.postSuccessField)) {
                Id sourceId = Id.valueOf(payment.Source_Record_Id__c);
                List<SObject> recs = Database.query(
                    'SELECT Id, ' + String.escapeSingleQuotes(config.postSuccessField)
                    + ' FROM ' + String.escapeSingleQuotes(payment.Source_Object__c)
                    + ' WHERE Id = :sourceId LIMIT 1');
                if (!recs.isEmpty()) {
                    recs[0].put(config.postSuccessField, config.postSuccessValue);
                    update recs[0];
                }
            }
            if (String.isNotBlank(config.postSuccessFlow)) {
                Flow.Interview.createInterview(config.postSuccessFlow, new Map<String, Object>{
                    'recordId' => payment.Source_Record_Id__c,
                    'paymentRecordId' => payment.Id,
                    'amount' => payment.Amount__c
                }).start();
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Post-payment action failed: ' + ex.getMessage());
        }
    }

    // ═══════════════════ Helpers ═══════════════════

    private static Map<String, Object> getEventObject(Map<String, Object> event) {
        Object dataObj = event.get('data');
        if (!(dataObj instanceof Map<String, Object>)) return null;
        Object obj = ((Map<String, Object>) dataObj).get('object');
        return (obj instanceof Map<String, Object>) ? (Map<String, Object>) obj : null;
    }

    private static void linkLog(Id logId, Id paymentId) {
        if (logId == null || paymentId == null) return;
        try { update new Stripe_Webhook_Log__c(Id = logId, Related_Payment__c = paymentId); }
        catch (Exception e) { /* non-fatal */ }
    }

    private static void respond(RestResponse res, Integer code, String body) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf(body);
    }

    /** Case-insensitive header lookup — Sites/proxies may normalize header casing. */
    private static String getHeaderIgnoreCase(RestRequest req, String name) {
        if (req == null || req.headers == null) return null;
        String direct = req.headers.get(name);
        if (String.isNotBlank(direct)) return direct;
        for (String k : req.headers.keySet()) {
            if (k != null && k.equalsIgnoreCase(name)) return req.headers.get(k);
        }
        return null;
    }

    private static String strOf(Object o) { return o != null ? String.valueOf(o) : null; }
    private static Decimal decOf(Object o) { try { return o != null ? Decimal.valueOf(String.valueOf(o)) : null; } catch (Exception e) { return null; } }
    private static DateTime epochToDt(Object o) {
        if (o == null) return null;
        try { return DateTime.newInstance(Long.valueOf(String.valueOf(o)) * 1000); } catch (Exception e) { return null; }
    }
}