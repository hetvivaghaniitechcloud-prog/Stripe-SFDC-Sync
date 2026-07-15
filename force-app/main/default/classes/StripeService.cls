/**
 * StripeService — global, dynamic passthrough to the Stripe API.
 *
 * Mirrors EasebuzzService: external callers (Flows, other packages, Apex) use
 * this thin global facade and never bind to the internal StripeApiService.
 * Auth is injected automatically via the org's Stripe Named Credential — the
 * secret key is never handled here.
 *
 * @author  Stripe Connector Package
 * @version 1.0
 */
global with sharing class StripeService {

    global class ApiResponse {
        @AuraEnabled global Boolean success;
        @AuraEnabled global Integer statusCode;
        @AuraEnabled global String rawBody;
        @AuraEnabled global String errorMessage;
        @AuraEnabled global String stripeId;
        @AuraEnabled global String clientSecret;
        @AuraEnabled global String hostedUrl;
        @AuraEnabled global Long responseTimeMs;
        global Map<String, Object> data;
        global ApiResponse() { this.success = false; this.data = new Map<String, Object>(); }

        private ApiResponse(StripeApiService.ApiResponse r) {
            this.success = r.success; this.statusCode = r.statusCode; this.rawBody = r.rawBody;
            this.errorMessage = r.errorMessage; this.stripeId = r.stripeId; this.clientSecret = r.clientSecret;
            this.hostedUrl = r.hostedUrl; this.responseTimeMs = r.responseTimeMs;
            this.data = r.data != null ? r.data : new Map<String, Object>();
        }
        private ApiResponse(String errorMsg) {
            this.success = false; this.statusCode = 0; this.errorMessage = errorMsg;
            this.data = new Map<String, Object>();
        }
    }

    /** Registry-based call — preferred. operation is a StripeApiService key. */
    global static ApiResponse callByType(String operation, Map<String,Object> body, String idempotencyKey) {
        try {
            return new ApiResponse(StripeApiService.callout(operation, body, idempotencyKey));
        } catch (Exception e) { return new ApiResponse(e.getMessage()); }
    }

    global static ApiResponse callByType(String operation, Map<String,String> pathParams,
                                         Map<String,Object> body, String idempotencyKey) {
        try {
            return new ApiResponse(StripeApiService.callout(operation, pathParams, body, idempotencyKey));
        } catch (Exception e) { return new ApiResponse(e.getMessage()); }
    }

    /**
     * Fully dynamic call. Caller controls method, path (relative to api.stripe.com),
     * body (Map/List → bracket-encoded, or raw String), query params, and idempotency key.
     * Auth + Stripe-Version are injected automatically via the Named Credential.
     */
    global static ApiResponse makeApiCall(String httpMethod, String path, Object body,
                                          Map<String,String> queryParams, String idempotencyKey) {
        Long start = DateTime.now().getTime();
        try {
            StripeConfigReader.Credentials creds = StripeConfigReader.getCredentials();
            if (creds == null || (String.isBlank(creds.secretKey) && String.isBlank(creds.namedCredential))) {
                return new ApiResponse('Stripe secret key not configured. Open Stripe Setup.');
            }
            String method = httpMethod.toUpperCase();
            Boolean useNamedCred = 'NAMED_CREDENTIAL'.equalsIgnoreCase(creds.authMode)
                && String.isNotBlank(creds.namedCredential);
            String url = useNamedCred ? ('callout:' + creds.namedCredential + path) : (StripeApiService.API_HOST + path);
            if (queryParams != null && !queryParams.isEmpty()) {
                List<String> q = new List<String>();
                for (String k : queryParams.keySet()) {
                    q.add(EncodingUtil.urlEncode(k,'UTF-8') + '=' + EncodingUtil.urlEncode(queryParams.get(k),'UTF-8'));
                }
                url += (path.contains('?') ? '&' : '?') + String.join(q, '&');
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod(method);
            req.setTimeout(creds.apiTimeoutMs != null ? creds.apiTimeoutMs : 30000);
            req.setHeader('Stripe-Version', creds.apiVersion);
            req.setHeader('Accept', 'application/json');
            if (!useNamedCred) req.setHeader('Authorization', 'Bearer ' + creds.secretKey);

            if (method == 'POST' || method == 'PUT') {
                req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
                if (String.isNotBlank(idempotencyKey)) req.setHeader('Idempotency-Key', idempotencyKey);
                String formBody = (body instanceof String)
                    ? (String) body
                    : (body != null ? StripeApiService.encodeFormPublic(body) : '');
                req.setBody(formBody);
            }

            HttpResponse hr = new Http().send(req);
            StripeApiService.ApiResponse internal = new StripeApiService.ApiResponse();
            internal.statusCode = hr.getStatusCode();
            internal.rawBody = hr.getBody();
            internal.responseTimeMs = DateTime.now().getTime() - start;
            StripeApiService.parseResponsePublic(internal);
            return new ApiResponse(internal);

        } catch (System.CalloutException ex) {
            return new ApiResponse('Callout failed: ' + ex.getMessage());
        } catch (Exception ex) {
            return new ApiResponse(ex.getMessage());
        }
    }

    global static ApiResponse get(String path, Map<String,String> queryParams)  { return makeApiCall('GET', path, null, queryParams, null); }
    global static ApiResponse post(String path, Object body, String idemKey)     { return makeApiCall('POST', path, body, null, idemKey); }
    global static ApiResponse del(String path)                                   { return makeApiCall('DELETE', path, null, null, null); }
}