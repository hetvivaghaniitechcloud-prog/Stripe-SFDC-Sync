/**
 * StripeApiService — HTTP callouts to the Stripe REST API.
 *
 * AUTH MODEL (delta from Easebuzz):
 *   Stripe uses a Bearer secret key in the Authorization header. We NEVER put
 *   that key in code or custom settings — it lives in a Named Credential.
 *   Every callout targets `callout:<NamedCredential><path>`; the platform
 *   injects `Authorization: Bearer sk_…` for us.
 *
 * REQUEST FORMAT (delta):
 *   Stripe requests are application/x-www-form-urlencoded with bracket notation
 *   for nested params, e.g. line_items[0][price]=price_123, metadata[udf1]=x.
 *   Responses are JSON. See https://docs.stripe.com/api.
 *
 * IDEMPOTENCY (Stripe-native, no Easebuzz analog):
 *   All POST create calls send an `Idempotency-Key` header so retries never
 *   double-charge. https://docs.stripe.com/api/idempotent_requests
 *
 * VERSION PINNING:
 *   A `Stripe-Version` header pins the API version for stable behaviour.
 *
 * @author  Stripe Connector Package
 * @version 1.0
 */
public with sharing class StripeApiService {

    public static final String API_HOST = 'https://api.stripe.com';

    // ───────────────────── Endpoint registry ─────────────────────
    // path may contain {id}; substituted from pathParams at call time.
    private static final Map<String, Endpoint> ENDPOINTS;
    static {
        ENDPOINTS = new Map<String, Endpoint>();
        // Checkout
        ENDPOINTS.put('CHECKOUT_SESSION_CREATE', ep('POST', '/v1/checkout/sessions'));
        ENDPOINTS.put('CHECKOUT_SESSION_GET',    ep('GET',  '/v1/checkout/sessions/{id}'));
        ENDPOINTS.put('CHECKOUT_SESSION_EXPIRE', ep('POST', '/v1/checkout/sessions/{id}/expire'));
        // PaymentIntents / SetupIntents
        ENDPOINTS.put('PAYMENT_INTENT_CREATE',   ep('POST', '/v1/payment_intents'));
        ENDPOINTS.put('PAYMENT_INTENT_GET',      ep('GET',  '/v1/payment_intents/{id}'));
        ENDPOINTS.put('SETUP_INTENT_CREATE',     ep('POST', '/v1/setup_intents'));
        ENDPOINTS.put('SETUP_INTENT_GET',        ep('GET',  '/v1/setup_intents/{id}'));
        // Customers
        ENDPOINTS.put('CUSTOMER_CREATE',         ep('POST', '/v1/customers'));
        ENDPOINTS.put('CUSTOMER_GET',            ep('GET',  '/v1/customers/{id}'));
        ENDPOINTS.put('CUSTOMER_SEARCH',         ep('GET',  '/v1/customers/search'));
        ENDPOINTS.put('CUSTOMER_UPDATE',         ep('POST', '/v1/customers/{id}'));
        // Catalog
        ENDPOINTS.put('PRODUCT_CREATE',          ep('POST', '/v1/products'));
        ENDPOINTS.put('PRICE_CREATE',            ep('POST', '/v1/prices'));
        ENDPOINTS.put('PRICE_LIST',              ep('GET',  '/v1/prices'));
        // Subscriptions
        ENDPOINTS.put('SUBSCRIPTION_CREATE',     ep('POST', '/v1/subscriptions'));
        ENDPOINTS.put('SUBSCRIPTION_GET',        ep('GET',  '/v1/subscriptions/{id}'));
        ENDPOINTS.put('SUBSCRIPTION_UPDATE',     ep('POST', '/v1/subscriptions/{id}'));
        ENDPOINTS.put('SUBSCRIPTION_CANCEL',     ep('DELETE', '/v1/subscriptions/{id}'));
        // Refunds
        ENDPOINTS.put('REFUND_CREATE',           ep('POST', '/v1/refunds'));
        ENDPOINTS.put('REFUND_GET',              ep('GET',  '/v1/refunds/{id}'));
        // Billing portal & payment links
        ENDPOINTS.put('BILLING_PORTAL_CREATE',   ep('POST', '/v1/billing_portal/sessions'));
        ENDPOINTS.put('PAYMENT_LINK_CREATE',     ep('POST', '/v1/payment_links'));
    }

    private static Endpoint ep(String method, String path) { return new Endpoint(method, path); }
    private class Endpoint { String method; String path; Endpoint(String m, String p){ method=m; path=p; } }

    // ───────────────────────── Response ─────────────────────────
    public class ApiResponse {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Integer statusCode;
        @AuraEnabled public String rawBody;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String stripeId;       // top-level "id" of created object
        @AuraEnabled public String clientSecret;   // for embedded/custom flows
        @AuraEnabled public String hostedUrl;      // for hosted checkout / payment links
        @AuraEnabled public Long responseTimeMs;
        public Map<String, Object> data;
        public ApiResponse() { this.success = false; this.data = new Map<String, Object>(); }
    }

    public class StripeException extends Exception {}

    // ───────────────────────── Core callout ─────────────────────────

    /**
     * @param operation     registry key (e.g. 'CHECKOUT_SESSION_CREATE')
     * @param pathParams    values for {id} placeholders (may be null)
     * @param body          nested params; recursively bracket-encoded for POST
     * @param idempotencyKey sent as Idempotency-Key header on POST (may be null)
     */
    public static ApiResponse callout(String operation, Map<String,String> pathParams,
                                       Map<String,Object> body, String idempotencyKey) {
        ApiResponse resp = new ApiResponse();
        Long start = DateTime.now().getTime();
        try {
            Endpoint cfg = ENDPOINTS.get(operation);
            if (cfg == null) {
                throw new StripeException('Unknown Stripe operation: "' + operation + '". Valid: '
                    + String.join(new List<String>(ENDPOINTS.keySet()), ', '));
            }

            StripeConfigReader.Credentials creds = StripeConfigReader.getCredentials();
            if (creds == null || (String.isBlank(creds.secretKey) && String.isBlank(creds.namedCredential))) {
                resp.errorMessage = 'Stripe secret key not configured. Open Stripe Setup → Credentials.';
                resp.responseTimeMs = DateTime.now().getTime() - start;
                return resp;
            }

            String path = substitutePath(cfg.path, pathParams);
            // Auth mode drives this: NAMED_CREDENTIAL → route through the NC (it injects auth,
            // supporting OAuth 2.0 / Custom); otherwise use the secret key (Bearer) directly.
            Boolean useNamedCred = 'NAMED_CREDENTIAL'.equalsIgnoreCase(creds.authMode)
                && String.isNotBlank(creds.namedCredential);
            String endpoint = useNamedCred ? ('callout:' + creds.namedCredential + path) : (API_HOST + path);

            HttpRequest req = new HttpRequest();
            req.setMethod(cfg.method);
            req.setTimeout(creds.apiTimeoutMs != null ? creds.apiTimeoutMs : 30000);
            req.setHeader('Stripe-Version', creds.apiVersion);
            req.setHeader('Accept', 'application/json');
            if (!useNamedCred) req.setHeader('Authorization', 'Bearer ' + creds.secretKey);

            String formBody = (body != null && !body.isEmpty()) ? encodeForm(body) : '';

            if (cfg.method == 'GET' || cfg.method == 'DELETE') {
                if (String.isNotBlank(formBody)) endpoint += (path.contains('?') ? '&' : '?') + formBody;
                req.setEndpoint(endpoint);
            } else {
                req.setEndpoint(endpoint);
                req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
                if (cfg.method == 'POST' && String.isNotBlank(idempotencyKey)) {
                    req.setHeader('Idempotency-Key', idempotencyKey);
                }
                req.setBody(formBody);
            }

            HttpResponse hr = new Http().send(req);
            resp.statusCode = hr.getStatusCode();
            resp.rawBody = hr.getBody();
            resp.responseTimeMs = DateTime.now().getTime() - start;
            parseResponse(resp);

        } catch (System.CalloutException ex) {
            resp.success = false;
            resp.errorMessage = 'Callout failed: ' + ex.getMessage()
                + '. Verify the Stripe Named Credential and CSP/Trusted Sites.';
            resp.responseTimeMs = DateTime.now().getTime() - start;
        } catch (Exception ex) {
            resp.success = false;
            resp.errorMessage = ex.getMessage();
            resp.responseTimeMs = DateTime.now().getTime() - start;
        }
        return resp;
    }

    public static ApiResponse callout(String operation, Map<String,Object> body, String idempotencyKey) {
        return callout(operation, null, body, idempotencyKey);
    }

    // ───────────────────────── Parsing ─────────────────────────

    private static void parseResponse(ApiResponse resp) {
        if (String.isBlank(resp.rawBody)) {
            resp.success = (resp.statusCode >= 200 && resp.statusCode < 300);
            if (!resp.success) resp.errorMessage = 'HTTP ' + resp.statusCode + ': empty response.';
            return;
        }
        Map<String, Object> root;
        try {
            root = (Map<String, Object>) JSON.deserializeUntyped(resp.rawBody);
        } catch (Exception e) {
            resp.success = false;
            resp.errorMessage = 'Non-JSON response from Stripe: ' + resp.rawBody.left(300);
            return;
        }
        resp.data = root;

        // Stripe errors: { "error": { "message":…, "type":…, "code":… } }
        if (resp.statusCode < 200 || resp.statusCode >= 300 || root.containsKey('error')) {
            resp.success = false;
            resp.errorMessage = extractError(root, resp.statusCode);
            return;
        }

        resp.success = true;
        if (root.get('id') != null) resp.stripeId = String.valueOf(root.get('id'));
        if (root.get('client_secret') != null) resp.clientSecret = String.valueOf(root.get('client_secret'));
        if (root.get('url') != null) resp.hostedUrl = String.valueOf(root.get('url'));
    }

    private static String extractError(Map<String,Object> root, Integer statusCode) {
        String prefix = 'HTTP ' + statusCode + ': ';
        Object errObj = root.get('error');
        if (errObj instanceof Map<String, Object>) {
            Map<String, Object> e = (Map<String, Object>) errObj;
            List<String> parts = new List<String>();
            if (e.get('message') != null) parts.add(String.valueOf(e.get('message')));
            if (e.get('code') != null)    parts.add('[' + e.get('code') + ']');
            if (e.get('param') != null)   parts.add('(param: ' + e.get('param') + ')');
            if (!parts.isEmpty()) return prefix + String.join(parts, ' ');
        } else if (errObj instanceof String) {
            return prefix + (String) errObj;
        }
        return prefix + 'Stripe request failed.';
    }

    // ───────────────────── Form encoding ─────────────────────
    // Recursively flattens nested Map/List into Stripe bracket notation.

    @TestVisible
    private static String encodeForm(Object value) {
        List<String> parts = new List<String>();
        encodeForm('', value, parts);
        return String.join(parts, '&');
    }

    private static void encodeForm(String prefix, Object value, List<String> parts) {
        if (value == null) return;
        if (value instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) value;
            for (String k : m.keySet()) {
                String key = String.isBlank(prefix) ? k : prefix + '[' + k + ']';
                encodeForm(key, m.get(k), parts);
            }
        } else if (value instanceof List<Object>) {
            List<Object> l = (List<Object>) value;
            for (Integer i = 0; i < l.size(); i++) {
                encodeForm(prefix + '[' + i + ']', l.get(i), parts);
            }
        } else {
            String v = (value instanceof Boolean) ? String.valueOf(value) : String.valueOf(value);
            parts.add(EncodingUtil.urlEncode(prefix, 'UTF-8') + '=' + EncodingUtil.urlEncode(v, 'UTF-8'));
        }
    }

    /** Public passthroughs used by the global StripeService facade. */
    public static String encodeFormPublic(Object body) { return encodeForm(body); }
    public static void parseResponsePublic(ApiResponse resp) { parseResponse(resp); }

    private static String substitutePath(String path, Map<String,String> pathParams) {
        if (pathParams == null) return path;
        String out = path;
        for (String k : pathParams.keySet()) {
            out = out.replace('{' + k + '}', EncodingUtil.urlEncode(pathParams.get(k), 'UTF-8'));
        }
        return out;
    }

    // ───────────────────── Metadata for UI ─────────────────────
    @AuraEnabled(cacheable=true)
    public static List<Map<String,String>> getApiRegistry() {
        List<Map<String,String>> out = new List<Map<String,String>>();
        for (String k : ENDPOINTS.keySet()) {
            Endpoint e = ENDPOINTS.get(k);
            out.add(new Map<String,String>{ 'operation'=>k, 'method'=>e.method, 'path'=>e.path });
        }
        return out;
    }
}