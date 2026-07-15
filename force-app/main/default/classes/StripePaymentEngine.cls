/**
 * StripePaymentEngine — single entry point for Stripe payment initiation.
 *
 * Object-agnostic: works with ANY Salesforce object via Stripe_Payment_Config__c
 * field mappings. Callable from Flow, Process Builder, Apex, and LWC.
 *
 * One-time modes (Sprint 1):
 *   HOSTED   → Checkout Session (ui_mode=hosted)   → redirect to session.url
 *   EMBEDDED → Checkout Session (ui_mode=embedded)  → mount session.client_secret
 *   CUSTOM   → PaymentIntent                        → confirm client_secret in Payment Element
 *   LINK     → Checkout Session (hosted) URL to send by email/SMS
 *
 * Stripe deltas vs Easebuzz:
 *   - amounts are sent in the smallest currency unit (e.g. cents) → x100.
 *   - UDF1–UDF10 map to Stripe metadata[...] (pass-through).
 *   - client_reference_id stores the Salesforce record Id.
 *   - an Idempotency-Key is sent on every create call.
 *
 * @author  Stripe Connector Package
 * @version 1.0
 */
public with sharing class StripePaymentEngine {

    public class PaymentRequest {
        @InvocableVariable(label='Record ID' description='Any Salesforce record ID' required=true)
        public Id recordId;
        @InvocableVariable(label='Amount' description='Major units (e.g. 49.99). If blank, from config mapping.')
        public Decimal amount;
        @InvocableVariable(label='Currency' description='ISO code e.g. usd, inr. Default from config or usd.')
        public String currencyCode;
        @InvocableVariable(label='Customer Name') public String customerName;
        @InvocableVariable(label='Customer Email') public String customerEmail;
        @InvocableVariable(label='Customer Phone') public String customerPhone;
        @InvocableVariable(label='Product Info') public String productInfo;
        @InvocableVariable(label='Checkout Mode' description='HOSTED, EMBEDDED, CUSTOM, or LINK')
        public String checkoutMode;
        @InvocableVariable(label='Config Name') public String configName;
        @InvocableVariable(label='UDF1') public String udf1;
        @InvocableVariable(label='UDF2') public String udf2;
        @InvocableVariable(label='UDF3') public String udf3;
        @InvocableVariable(label='UDF4') public String udf4;
        @InvocableVariable(label='UDF5') public String udf5;
        @InvocableVariable(label='UDF6') public String udf6;
        @InvocableVariable(label='UDF7') public String udf7;
        @InvocableVariable(label='UDF8') public String udf8;
        @InvocableVariable(label='UDF9') public String udf9;
        @InvocableVariable(label='UDF10') public String udf10;
    }

    public class PaymentResult {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String checkoutMode;
        @InvocableVariable public String hostedUrl;        // HOSTED / LINK
        @InvocableVariable public String clientSecret;     // EMBEDDED / CUSTOM
        @InvocableVariable public String publishableKey;   // for Stripe.js
        @InvocableVariable public String checkoutSessionId;
        @InvocableVariable public String paymentIntentId;
        @InvocableVariable public Id paymentRecordId;
        @InvocableVariable public String errorMessage;
    }

    // ───────────────────── Invocable (Flow / Apex) ─────────────────────
    @InvocableMethod(label='Initiate Stripe Payment'
        description='Create a Stripe Checkout Session or PaymentIntent from any record.'
        category='Stripe')
    public static List<PaymentResult> initiatePayment(List<PaymentRequest> requests) {
        List<PaymentResult> results = new List<PaymentResult>();
        for (PaymentRequest req : requests) results.add(process(req));
        return results;
    }

    // ───────────────────── LWC entry (one-time) ─────────────────────
    @AuraEnabled
    public static String initiatePaymentLWC(Id recordId, Decimal amount, String currencyCode,
            String customerName, String customerEmail, String customerPhone, String productInfo,
            String checkoutMode, String configName, String hiddenParamsJson) {
        PaymentRequest req = new PaymentRequest();
        req.recordId = recordId; req.amount = amount; req.currencyCode = currencyCode;
        req.customerName = customerName; req.customerEmail = customerEmail; req.customerPhone = customerPhone;
        req.productInfo = productInfo; req.checkoutMode = checkoutMode; req.configName = configName;
        applyHiddenParams(req, hiddenParamsJson);
        return JSON.serialize(process(req));
    }

    private static void applyHiddenParams(PaymentRequest req, String hiddenParamsJson) {
        if (String.isBlank(hiddenParamsJson)) return;
        try {
            Map<String, Object> h = (Map<String, Object>) JSON.deserializeUntyped(hiddenParamsJson);
            req.udf1 = sv(h,'udf1'); req.udf2 = sv(h,'udf2'); req.udf3 = sv(h,'udf3'); req.udf4 = sv(h,'udf4');
            req.udf5 = sv(h,'udf5'); req.udf6 = sv(h,'udf6'); req.udf7 = sv(h,'udf7'); req.udf8 = sv(h,'udf8');
            req.udf9 = sv(h,'udf9'); req.udf10 = sv(h,'udf10');
        } catch (Exception e) { /* best-effort */ }
    }

    // ───────────────── Guest entry (Experience Cloud / public site) ─────────────────
    /**
     * Guest-safe checkout. Takes ONLY a config name + minimal customer fields.
     * The amount/price is resolved SERVER-SIDE from the config (a HARDCODED amount
     * mapping or a fixed Price Id) — never from the client. Returns only the
     * client_secret / hosted url + publishable key. The secret key is never exposed.
     *
     * The config must have Guest_Enabled__c = true. Assign the Stripe Guest
     * permission set to the site's guest user so the payment record can be written.
     */
    @AuraEnabled
    public static String createGuestCheckoutSession(String configName, String customerName,
            String customerEmail, String customerPhone) {
        Map<String, Object> out = new Map<String, Object>{ 'success' => false };
        try {
            StripeConfigReader.PaymentConfig config = StripeConfigReader.getConfig(configName, null);
            if (config == null) { out.put('message', 'Unknown payment configuration.'); return JSON.serialize(out); }
            if (config.guestEnabled != true) { out.put('message', 'This configuration is not enabled for guest checkout.'); return JSON.serialize(out); }

            StripeConfigReader.Credentials creds = StripeConfigReader.getCredentials();
            if (creds == null || String.isBlank(creds.publishableKey)
                || (String.isBlank(creds.secretKey) && String.isBlank(creds.namedCredential))) {
                out.put('message', 'Stripe is not configured.'); return JSON.serialize(out);
            }

            // Server-side amount/price resolution — the client cannot influence it.
            String mode = String.isNotBlank(config.checkoutMode) ? config.checkoutMode.toUpperCase() : 'HOSTED';
            String idem = 'guest_' + (configName != null ? configName : 'cfg') + '_' + DateTime.now().getTime();

            ResolvedParams rp = new ResolvedParams();
            rp.currencyCode = String.isNotBlank(config.currencyCode) ? config.currencyCode.toLowerCase() : 'usd';
            rp.name = String.isNotBlank(customerName) ? customerName : 'Guest';
            rp.email = customerEmail;
            rp.phone = customerPhone;
            rp.productInfo = 'Payment';
            if (String.isNotBlank(customerEmail)) rp.metadata.put('guest_email', customerEmail);

            Map<String, Object> body;
            String operation;
            if (String.isNotBlank(config.priceId)) {
                // Fixed Price — one-time or recurring depending on the Price in Stripe.
                body = new Map<String, Object>{
                    'mode' => (config.paymentType == 'Recurring') ? 'subscription' : 'payment',
                    'ui_mode' => (mode == 'EMBEDDED') ? 'embedded' : 'hosted',
                    'line_items' => new List<Object>{ new Map<String, Object>{ 'price' => config.priceId, 'quantity' => 1 } }
                };
                operation = 'CHECKOUT_SESSION_CREATE';
            } else {
                // HARDCODED amount in the config's Amount_Field mapping (no record for guests).
                StripeConfigReader.FieldConfig amtCfg = StripeConfigReader.decodeFieldConfig(config.amountField);
                if (amtCfg.sourceType != 'HARDCODED' || String.isBlank(amtCfg.value)) {
                    out.put('message', 'Guest config must use a fixed Price Id or a HARDCODED amount.');
                    return JSON.serialize(out);
                }
                Decimal amount = Decimal.valueOf(amtCfg.value);
                rp.amountMinor = (amount * 100).setScale(0, System.RoundingMode.HALF_UP).longValue();
                body = buildCheckoutSessionBody(rp, mode == 'EMBEDDED' ? 'EMBEDDED' : 'HOSTED', creds);
                operation = 'CHECKOUT_SESSION_CREATE';
            }
            if (String.isNotBlank(customerEmail)) body.put('customer_email', customerEmail);

            StripeApiService.ApiResponse api = StripeApiService.callout(operation, body, idem);
            Stripe_Payment__c payment = writePayment(rp, api,
                (mode == 'EMBEDDED') ? 'EMBEDDED' : 'HOSTED', null, null, config.configName, idem);

            out.put('success', api.success);
            out.put('checkoutSessionId', api.stripeId);
            out.put('clientSecret', api.clientSecret);
            out.put('hostedUrl', api.hostedUrl);
            out.put('publishableKey', creds.publishableKey);   // pk_… only
            out.put('paymentRecordId', payment.Id);
            out.put('message', api.errorMessage);
        } catch (Exception e) {
            out.put('message', e.getMessage());
        }
        return JSON.serialize(out);
    }

    // ───────────────────── Core ─────────────────────
    @TestVisible
    private static PaymentResult process(PaymentRequest req) {
        PaymentResult result = new PaymentResult();
        try {
            String objectApiName = req.recordId != null
                ? req.recordId.getSObjectType().getDescribe().getName() : null;

            StripeConfigReader.PaymentConfig config =
                StripeConfigReader.getConfig(req.configName, objectApiName);
            if (config == null) {
                result.success = false;
                result.errorMessage = 'No Stripe Payment Config found' +
                    (objectApiName != null ? ' for object: ' + objectApiName : '') + '.';
                return result;
            }
            StripeConfigReader.Credentials creds = StripeConfigReader.getCredentials();
            if (creds == null || (String.isBlank(creds.secretKey) && String.isBlank(creds.namedCredential))
                    || String.isBlank(creds.publishableKey)) {
                result.success = false;
                result.errorMessage = 'Stripe credentials not configured. Open Stripe Setup.';
                return result;
            }

            SObject rec = (req.recordId != null) ? querySourceRecord(req.recordId, objectApiName, config) : null;
            ResolvedParams rp = resolveParams(req, config, rec);

            String mode = firstNonBlank(req.checkoutMode, config.checkoutMode, 'HOSTED').toUpperCase();
            String idemKey = buildIdempotencyKey(req.recordId, mode);

            StripeApiService.ApiResponse api;
            String operation;
            if (mode == 'CUSTOM') {
                operation = 'PAYMENT_INTENT_CREATE';
                api = StripeApiService.callout(operation, buildPaymentIntentBody(rp), idemKey);
            } else {
                operation = 'CHECKOUT_SESSION_CREATE';
                api = StripeApiService.callout(operation, buildCheckoutSessionBody(rp, mode, creds), idemKey);
            }

            Stripe_Payment__c payment = writePayment(rp, api, mode, objectApiName, req.recordId, config.configName, idemKey);

            result.success = api.success;
            result.checkoutMode = mode;
            result.paymentRecordId = payment.Id;
            result.publishableKey = creds.publishableKey;
            result.errorMessage = api.errorMessage;
            if (mode == 'CUSTOM') {
                result.clientSecret = api.clientSecret;
                result.paymentIntentId = api.stripeId;
            } else {
                result.checkoutSessionId = api.stripeId;
                result.clientSecret = api.clientSecret;   // populated for EMBEDDED
                result.hostedUrl = api.hostedUrl;          // populated for HOSTED / LINK
            }
        } catch (Exception ex) {
            result.success = false;
            result.errorMessage = ex.getMessage();
            System.debug(LoggingLevel.ERROR, 'StripePaymentEngine: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
        }
        return result;
    }

    // ───────────────────── Param resolution ─────────────────────
    private class ResolvedParams {
        Long amountMinor;
        String currencyCode;
        String name;
        String email;
        String phone;
        String productInfo;
        Id recordId;
        Boolean collectBillingAddress = false;
        Map<String, String> metadata = new Map<String, String>();
    }

    private static ResolvedParams resolveParams(PaymentRequest req,
            StripeConfigReader.PaymentConfig config, SObject rec) {
        ResolvedParams rp = new ResolvedParams();
        rp.recordId = req.recordId;

        Decimal amount = req.amount;
        if (amount == null && rec != null && String.isNotBlank(config.amountField)) {
            Object v = getFieldVal(rec, config.amountField);
            if (v != null) try { amount = Decimal.valueOf(String.valueOf(v)); } catch (Exception e) {}
        }
        if (amount == null) amount = 0;
        rp.amountMinor = (amount * 100).setScale(0, System.RoundingMode.HALF_UP).longValue();

        rp.currencyCode = firstNonBlank(req.currencyCode, config.currencyCode, 'usd').toLowerCase();
        rp.name = firstNonBlank(req.customerName, fieldStr(rec, config.nameField), 'Customer');
        rp.email = firstNonBlank(req.customerEmail, fieldStr(rec, config.emailField), null);
        rp.phone = firstNonBlank(req.customerPhone, fieldStr(rec, config.phoneField), null);
        rp.productInfo = firstNonBlank(req.productInfo, fieldStr(rec, config.productInfoField), 'Payment');
        rp.collectBillingAddress = (config.collectBillingAddress == true);

        // metadata: UDF1-10 from request override → config mapping
        String[] reqUdf = new String[]{ req.udf1, req.udf2, req.udf3, req.udf4, req.udf5,
            req.udf6, req.udf7, req.udf8, req.udf9, req.udf10 };
        for (Integer i = 0; i < 10; i++) {
            String val = reqUdf[i];
            if (String.isBlank(val) && config.udfFields != null && i < config.udfFields.size()) {
                val = fieldStr(rec, config.udfFields[i]);
            }
            if (String.isNotBlank(val)) rp.metadata.put('udf' + (i + 1), val);
        }
        if (rp.recordId != null) rp.metadata.put('sf_record_id', String.valueOf(rp.recordId));
        return rp;
    }

    // ───────────────────── Body builders ─────────────────────
    private static Map<String, Object> buildCheckoutSessionBody(ResolvedParams rp, String mode,
            StripeConfigReader.Credentials creds) {
        Map<String, Object> body = new Map<String, Object>();
        body.put('mode', 'payment');
        body.put('ui_mode', (mode == 'EMBEDDED') ? 'embedded' : 'hosted');

        // single inline line item (price_data) — no pre-existing Price needed for one-time
        Map<String, Object> priceData = new Map<String, Object>{
            'currency' => rp.currencyCode,
            'unit_amount' => rp.amountMinor,
            'product_data' => new Map<String, Object>{ 'name' => rp.productInfo }
        };
        body.put('line_items', new List<Object>{
            new Map<String, Object>{ 'price_data' => priceData, 'quantity' => 1 }
        });

        if (String.isNotBlank(rp.email)) body.put('customer_email', rp.email);
        if (rp.recordId != null) body.put('client_reference_id', String.valueOf(rp.recordId));
        if (!rp.metadata.isEmpty()) {
            body.put('metadata', rp.metadata);
            // Copy metadata onto the PaymentIntent so failed attempts (which fire before
            // checkout.session.completed sets the PI id on our record) can still be linked.
            body.put('payment_intent_data', new Map<String, Object>{ 'metadata' => rp.metadata });
        }
        // Collect the full billing address (required for India export accounts).
        body.put('billing_address_collection', rp.collectBillingAddress ? 'required' : 'auto');

        // EMBEDDED completes IN-PLACE (no redirect) so the iframe popup's onComplete
        // fires — avoids redirecting to a non-existent return page. HOSTED redirects.
        if (mode == 'EMBEDDED') {
            body.put('redirect_on_completion', 'never');
        } else {
            body.put('success_url', appendSessionId(firstNonBlank(creds.successUrl, defaultReturnUrl(), defaultReturnUrl())));
            body.put('cancel_url', firstNonBlank(creds.cancelUrl, defaultReturnUrl(), defaultReturnUrl()));
        }
        return body;
    }

    private static Map<String, Object> buildPaymentIntentBody(ResolvedParams rp) {
        Map<String, Object> body = new Map<String, Object>{
            'amount' => rp.amountMinor,
            'currency' => rp.currencyCode,
            'automatic_payment_methods' => new Map<String, Object>{ 'enabled' => true }
        };
        if (String.isNotBlank(rp.email)) body.put('receipt_email', rp.email);
        if (!rp.metadata.isEmpty()) body.put('metadata', rp.metadata);
        return body;
    }

    // ───────────────────── Persistence ─────────────────────
    private static Stripe_Payment__c writePayment(ResolvedParams rp, StripeApiService.ApiResponse api,
            String mode, String objectApiName, Id recordId, String configName, String idemKey) {
        Stripe_Payment__c p = new Stripe_Payment__c(
            Amount__c = rp.amountMinor != null ? (Decimal.valueOf(rp.amountMinor) / 100) : 0,
            Currency__c = rp.currencyCode,
            Customer_Name__c = rp.name,
            Customer_Email__c = rp.email,
            Customer_Phone__c = rp.phone,
            Product_Info__c = rp.productInfo,
            Payment_Type__c = 'One-Time',
            Checkout_Mode__c = mode,
            Config_Name__c = configName,
            Source_Object__c = objectApiName,
            Source_Record_Id__c = recordId != null ? String.valueOf(recordId) : null,
            Status__c = api.success ? 'Initiated' : 'Error',
            Idempotency_Key__c = idemKey,
            Raw_Response__c = api.rawBody != null ? api.rawBody.left(131072) : null,
            Error_Message__c = api.errorMessage
        );
        if (mode == 'CUSTOM') {
            p.Payment_Intent_Id__c = api.stripeId;
        } else {
            p.Checkout_Session_Id__c = api.stripeId;
            p.Hosted_Url__c = api.hostedUrl;
        }
        // metadata → UDF fields
        p.UDF1__c = rp.metadata.get('udf1'); p.UDF2__c = rp.metadata.get('udf2');
        p.UDF3__c = rp.metadata.get('udf3'); p.UDF4__c = rp.metadata.get('udf4');
        p.UDF5__c = rp.metadata.get('udf5'); p.UDF6__c = rp.metadata.get('udf6');
        p.UDF7__c = rp.metadata.get('udf7'); p.UDF8__c = rp.metadata.get('udf8');
        p.UDF9__c = rp.metadata.get('udf9'); p.UDF10__c = rp.metadata.get('udf10');

        if (Schema.sObjectType.Stripe_Payment__c.isCreateable()) insert p;
        return p;
    }

    // ───────────────────── Query ─────────────────────
    private static SObject querySourceRecord(Id recordId, String objectApiName,
            StripeConfigReader.PaymentConfig config) {
        Set<String> fields = new Set<String>{ 'Id' };
        addField(fields, config.amountField);
        addField(fields, config.nameField);
        addField(fields, config.emailField);
        addField(fields, config.phoneField);
        addField(fields, config.productInfoField);
        if (config.udfFields != null) for (String f : config.udfFields) addField(fields, f);

        Map<String, Schema.SObjectField> fmap =
            Schema.getGlobalDescribe().get(objectApiName)?.getDescribe().fields.getMap();
        Set<String> safe = new Set<String>{ 'Id' };
        for (String f : fields) {
            if (f == 'Id') continue;
            if (f.contains('.')) { safe.add(f); continue; } // relationship — describe-validated upstream
            if (fmap != null && fmap.containsKey(f.toLowerCase())
                && fmap.get(f.toLowerCase()).getDescribe().isAccessible()) {
                safe.add(f);
            }
        }
        String soql = 'SELECT ' + String.join(new List<String>(safe), ', ')
            + ' FROM ' + String.escapeSingleQuotes(objectApiName) + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : rows[0];
    }

    private static void addField(Set<String> fields, String raw) {
        StripeConfigReader.FieldConfig cfg = StripeConfigReader.decodeFieldConfig(raw);
        if (cfg.sourceType == 'FIELD' && String.isNotBlank(cfg.value)) fields.add(cfg.value);
    }

    // ───────────────────── Helpers ─────────────────────
    private static String buildIdempotencyKey(Id recordId, String mode) {
        return 'SP_' + (recordId != null ? String.valueOf(recordId) : 'noRec')
            + '_' + mode + '_' + DateTime.now().getTime();
    }

    private static String defaultReturnUrl() {
        return URL.getOrgDomainUrl().toExternalForm() + '/stripe/return';
    }
    private static String appendSessionId(String url) {
        if (String.isBlank(url)) return url;
        return url + (url.contains('?') ? '&' : '?') + 'session_id={CHECKOUT_SESSION_ID}';
    }

    private static Object getFieldVal(SObject rec, String raw) {
        StripeConfigReader.FieldConfig cfg = StripeConfigReader.decodeFieldConfig(raw);
        if (cfg.sourceType == 'HARDCODED') return cfg.value;
        if (cfg.sourceType != 'FIELD' || rec == null || String.isBlank(cfg.value)) return null;
        try {
            List<String> parts = cfg.value.split('\\.');
            SObject cur = rec;
            for (Integer i = 0; i < parts.size() - 1; i++) { cur = cur.getSObject(parts[i]); if (cur == null) return null; }
            return cur.get(parts[parts.size() - 1]);
        } catch (Exception e) { return null; }
    }
    private static String fieldStr(SObject rec, String raw) {
        Object v = getFieldVal(rec, raw);
        return v != null ? String.valueOf(v) : null;
    }
    private static String firstNonBlank(String a, String b, String c) {
        if (String.isNotBlank(a)) return a;
        if (String.isNotBlank(b)) return b;
        return c;
    }
    private static String sv(Map<String,Object> m, String k) { Object v = m.get(k); return v != null ? String.valueOf(v) : null; }
}