/**
 * StripeConfigReader — reads/writes Stripe connector settings.
 *
 *   • Credentials  → Stripe_Credentials__c  (Protected Hierarchy custom setting)
 *   • Payment cfg  → Stripe_Payment_Config__c (List custom setting, runtime-editable)
 *
 * Mirrors EasebuzzConfigReader. Key Stripe deltas:
 *   - There is NO secret key here. The Stripe secret key lives ONLY in the
 *     Named Credential. This class exposes the *publishable* key (safe for
 *     clients) and the *name* of the Named Credential to use.
 *   - Webhook signing secrets support rotation: the field may hold several
 *     whsec_… values separated by comma / newline; getWebhookSecrets() returns
 *     them all so the handler can accept any.
 *
 * Security: all SOQL runs WITH USER_MODE; dynamic queries use
 * Database.query(..., AccessLevel.USER_MODE) with explicit isAccessible checks.
 *
 * @author  Stripe Connector Package
 * @version 1.0
 */
public with sharing class StripeConfigReader {

    // ───────────────────────── Wrappers ─────────────────────────

    public class Credentials {
        public String environment;          // 'test' | 'live'
        public String authMode;             // 'KEY' | 'NAMED_CREDENTIAL'
        public String publishableKey;       // pk_… (safe for client)
        public String secretKey;            // sk_… (SERVER ONLY — never returned to a client)
        public String namedCredential;      // Named Credential name (used when authMode = NAMED_CREDENTIAL)
        public String defaultCurrency;
        public String defaultProductInfo;
        public String hostedRedirect;       // 'newtab' | 'same'
        public String webhookBaseUrl;       // public Site base URL for webhook delivery
        public String webhookUrl;
        public List<String> webhookSecrets; // whsec_… (one or more, rotation-aware)
        public String apiVersion;           // pinned Stripe-Version
        public Boolean hostedEnabled;
        public Boolean embeddedEnabled;
        public Boolean customElementEnabled;
        public Boolean linkEnabled;
        public Boolean customerPortalEnabled;
        public String successUrl;
        public String cancelUrl;
        public String returnUrl;
        public String logoUrl;
        public Integer apiTimeoutMs;
        public Integer retryCount;
    }

    public class PaymentConfig {
        public String configName;
        public String sourceObject;
        public String checkoutMode;
        public String paymentType;        // One-Time | Recurring
        public String amountField;
        public String nameField;
        public String emailField;
        public String phoneField;
        public String productInfoField;
        public List<String> udfFields;
        public String priceId;
        public String priceIdField;
        public Integer trialDays;
        public Boolean allowPromotionCodes;
        public Boolean collectBillingAddress;
        public Boolean savePaymentMethod;
        public Boolean guestEnabled;
        public String allowedPaymentMethods;
        public String currencyCode;
        public String postSuccessField;
        public String postSuccessValue;
        public String postSuccessFlow;
        public Boolean sendNotification;
        public Boolean isActive;
    }

    public class WebhookTestStatus {
        @AuraEnabled public Boolean connected;
        @AuraEnabled public Boolean pending;
        @AuraEnabled public String token;
        @AuraEnabled public String message;
        @AuraEnabled public String customerId;
        @AuraEnabled public String eventId;
        @AuraEnabled public Datetime requestedAt;
        @AuraEnabled public Datetime receivedAt;
    }
    public static final String DEFAULT_API_VERSION = '2024-06-20';

    // ═══════════════════════ CREDENTIALS ═══════════════════════

    /** Internal accessor — includes Named Credential name + webhook secrets.
     *  NEVER returns the Stripe secret key (it is not stored in Salesforce). */
    public static Credentials getCredentials() {
        Stripe_Credentials__c cr = Stripe_Credentials__c.getOrgDefaults();
        if (cr == null) return null;

        Credentials c = new Credentials();
        c.environment = String.isNotBlank(cr.Environment__c) ? cr.Environment__c.toLowerCase() : 'test';
        Boolean isLive = (c.environment == 'live');

        c.authMode        = String.isNotBlank(cr.Auth_Mode__c) ? cr.Auth_Mode__c : 'KEY';
        c.publishableKey  = isLive ? cr.Publishable_Key_Live__c   : cr.Publishable_Key_Test__c;
        c.secretKey       = isLive ? cr.Secret_Key_Live__c         : cr.Secret_Key_Test__c;
        c.namedCredential = isLive ? cr.Named_Credential_Live__c   : cr.Named_Credential_Test__c;
        c.defaultCurrency = String.isNotBlank(cr.Default_Currency__c) ? cr.Default_Currency__c.toLowerCase() : null;
        c.defaultProductInfo = cr.Default_Product_Info__c;
        c.hostedRedirect  = cr.Hosted_Redirect__c;
        c.webhookBaseUrl  = cr.Webhook_Base_Url__c;
        c.webhookUrl = cr.Webhook_Url__c;
        c.webhookSecrets  = parseSecrets(isLive ? cr.Webhook_Signing_Secret_Live__c
                                                 : cr.Webhook_Signing_Secret_Test__c);
        c.apiVersion = String.isNotBlank(cr.Stripe_Api_Version__c) ? cr.Stripe_Api_Version__c : DEFAULT_API_VERSION;
        c.hostedEnabled         = cr.Hosted_Enabled__c;
        c.embeddedEnabled       = cr.Embedded_Enabled__c;
        c.customElementEnabled  = cr.Custom_Element_Enabled__c;
        c.linkEnabled           = cr.Link_Enabled__c;
        c.customerPortalEnabled = cr.Customer_Portal_Enabled__c;
        c.successUrl = cr.Success_Url__c;
        c.cancelUrl  = cr.Cancel_Url__c;
        c.returnUrl  = cr.Return_Url__c;
        c.logoUrl    = cr.Custom_Logo_Url__c;
        c.apiTimeoutMs = cr.Api_Timeout__c != null ? Integer.valueOf(cr.Api_Timeout__c) : 30000;
        c.retryCount   = cr.Retry_Count__c != null ? Integer.valueOf(cr.Retry_Count__c) : 0;
        return c;
    }

    /** Webhook signing secrets (rotation-aware) for the active environment. */
    public static List<String> getWebhookSecrets() {
        Credentials c = getCredentials();
        return (c == null || c.webhookSecrets == null) ? new List<String>() : c.webhookSecrets;
    }

    private static List<String> parseSecrets(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) return out;
        for (String s : raw.split('[,\\s]+')) {
            if (String.isNotBlank(s)) out.add(s.trim());
        }
        return out;
    }

    /** Client-safe credential info for LWCs — publishable key + enabled modes ONLY. */
    @AuraEnabled(cacheable=false)
    public static String getCredentialsInfo() {
        Stripe_Credentials__c cr = Stripe_Credentials__c.getOrgDefaults();
        Credentials c = getCredentials();
        Boolean hasAuth = c != null && (String.isNotBlank(c.secretKey) || String.isNotBlank(c.namedCredential));
        Boolean configured = hasAuth && c != null && String.isNotBlank(c.publishableKey);
        String webhookBaseUrl =
            c != null && String.isNotBlank(c.webhookBaseUrl)
                ? c.webhookBaseUrl
                : getDefaultWebhookBaseUrl();

        String webhookUrl;

        if (
            c != null &&
            String.isNotBlank(c.webhookUrl)
        ) {
            webhookUrl =
                c.webhookUrl.trim();
        } else {
            webhookUrl =
                buildWebhookUrl(c);
        }
        // NOTE: the secret key is intentionally NEVER included in this payload.
        return JSON.serialize(new Map<String, Object>{
            'isConfigured'         => configured,
            'environment'          => c != null ? c.environment : 'test',
            'publishableKey'       => c != null ? c.publishableKey : null,  // pk_… is safe to expose
            'apiVersion'           => c != null ? c.apiVersion : DEFAULT_API_VERSION,
            'hostedEnabled'        => c != null ? c.hostedEnabled : false,
            'embeddedEnabled'      => c != null ? c.embeddedEnabled : false,
            'customElementEnabled' => c != null ? c.customElementEnabled : false,
            'linkEnabled'          => c != null ? c.linkEnabled : false,
            'customerPortalEnabled'=> c != null ? c.customerPortalEnabled : false,
            'secretKeySet'         => c != null && String.isNotBlank(c.secretKey),
            'secretKeyMasked'      => c != null && String.isNotBlank(c.secretKey) ? mask(c.secretKey) : '',
            'publishableKeyMasked' => c != null && String.isNotBlank(c.publishableKey) ? mask(c.publishableKey) : '',
            'namedCredentialSet'   => c != null && String.isNotBlank(c.namedCredential),
            'webhookSecretSet'     => c != null && !c.webhookSecrets.isEmpty(),
            // full (non-secret) config for the setup console
            'authMode'             => c != null && String.isNotBlank(c.authMode) ? c.authMode : 'KEY',
            'namedCredential'      => c != null ? c.namedCredential : null,
            'defaultCurrency'      => c != null && String.isNotBlank(c.defaultCurrency) ? c.defaultCurrency : 'usd',
            'defaultProductInfo'   => c != null ? c.defaultProductInfo : null,
            'hostedRedirect'       => c != null && String.isNotBlank(c.hostedRedirect) ? c.hostedRedirect : 'newtab',
            'successUrl'           => c != null ? c.successUrl : null,
            'cancelUrl'            => c != null ? c.cancelUrl : null,
            'returnUrl'            => c != null ? c.returnUrl : null,
            'logoUrl'              => c != null ? c.logoUrl : null,
            'apiTimeoutSec'        => c != null && c.apiTimeoutMs != null ? c.apiTimeoutMs / 1000 : 30,
            'webhookBaseUrl'       =>  c != null ? c.webhookBaseUrl : null,
            'webhookUrl'           => webhookUrl
        });
    }

    /** Persist non-secret credential fields from the setup UI. The Stripe secret
     *  key is NOT accepted here — it is entered into the Named Credential. */
    @AuraEnabled
    public static String saveCredentials(String credJson) {
        try {
            Map<String, Object> d = (Map<String, Object>) JSON.deserializeUntyped(credJson);
            Stripe_Credentials__c cr = Stripe_Credentials__c.getOrgDefaults();
            if (cr == null || cr.Id == null) {
                cr = new Stripe_Credentials__c(SetupOwnerId = UserInfo.getOrganizationId());
            }
            if (d.containsKey('environment'))           cr.Environment__c = gs(d,'environment');
            if (d.containsKey('publishableKeyTest'))    cr.Publishable_Key_Test__c = gs(d,'publishableKeyTest');
            if (d.containsKey('publishableKeyLive'))    cr.Publishable_Key_Live__c = gs(d,'publishableKeyLive');
            if (d.containsKey('secretKeyTest'))         cr.Secret_Key_Test__c = gs(d,'secretKeyTest');
            if (d.containsKey('secretKeyLive'))         cr.Secret_Key_Live__c = gs(d,'secretKeyLive');
            if (d.containsKey('namedCredentialTest'))   cr.Named_Credential_Test__c = gs(d,'namedCredentialTest');
            if (d.containsKey('namedCredentialLive'))   cr.Named_Credential_Live__c = gs(d,'namedCredentialLive');
            if (d.containsKey('webhookSecretTest'))     cr.Webhook_Signing_Secret_Test__c = gs(d,'webhookSecretTest');
            if (d.containsKey('webhookSecretLive'))     cr.Webhook_Signing_Secret_Live__c = gs(d,'webhookSecretLive');
            if (d.containsKey('apiVersion'))            cr.Stripe_Api_Version__c = gs(d,'apiVersion');
            if (d.containsKey('hostedEnabled'))         cr.Hosted_Enabled__c = bool(d,'hostedEnabled');
            if (d.containsKey('embeddedEnabled'))       cr.Embedded_Enabled__c = bool(d,'embeddedEnabled');
            if (d.containsKey('customElementEnabled'))  cr.Custom_Element_Enabled__c = bool(d,'customElementEnabled');
            if (d.containsKey('linkEnabled'))           cr.Link_Enabled__c = bool(d,'linkEnabled');
            if (d.containsKey('customerPortalEnabled')) cr.Customer_Portal_Enabled__c = bool(d,'customerPortalEnabled');
            if (d.containsKey('successUrl'))            cr.Success_Url__c = gs(d,'successUrl');
            if (d.containsKey('cancelUrl'))             cr.Cancel_Url__c = gs(d,'cancelUrl');
            if (d.containsKey('returnUrl'))             cr.Return_Url__c = gs(d,'returnUrl');
            if (d.containsKey('logoUrl'))               cr.Custom_Logo_Url__c = gs(d,'logoUrl');
            if (d.containsKey('authMode'))              cr.Auth_Mode__c = gs(d,'authMode');
            if (d.containsKey('namedCredential')) {
                // single NC field in the console → apply to the active environment
                Boolean isLiveEnv = 'live'.equalsIgnoreCase(gs(d,'environment'));
                if (isLiveEnv) cr.Named_Credential_Live__c = gs(d,'namedCredential');
                else cr.Named_Credential_Test__c = gs(d,'namedCredential');
            }
            if (d.containsKey('defaultCurrency'))       cr.Default_Currency__c = gs(d,'defaultCurrency');
            if (d.containsKey('defaultProductInfo'))    cr.Default_Product_Info__c = gs(d,'defaultProductInfo');
            if (d.containsKey('hostedRedirect'))        cr.Hosted_Redirect__c = gs(d,'hostedRedirect');
            if (d.containsKey('webhookBaseUrl'))        cr.Webhook_Base_Url__c = gs(d,'webhookBaseUrl');
            if (d.containsKey('webhookUrl'))            cr.Webhook_Url__c = gs(d, 'webhookUrl');
            if (d.containsKey('apiTimeoutSec') && d.get('apiTimeoutSec') != null)
                cr.Api_Timeout__c = Decimal.valueOf(String.valueOf(d.get('apiTimeoutSec'))) * 1000;
            upsert cr;
            return ok(new Map<String, Object>{'message' => 'Configuration saved.'});
        } catch (Exception e) { return err(e.getMessage()); }
    }

    /** Test the connection by retrieving the Stripe account. Returns account id + country. */
    @AuraEnabled
    public static String testConnection() {
        try {
            StripeService.ApiResponse r = StripeService.get('/v1/account', null);
            if (!r.success) return err(r.errorMessage);
            String acctId = r.data != null ? String.valueOf(r.data.get('id')) : null;
            String country = r.data != null ? String.valueOf(r.data.get('country')) : null;
            String cur = r.data != null ? String.valueOf(r.data.get('default_currency')) : null;
            return ok(new Map<String, Object>{
                'message' => 'Connected to Stripe.', 'accountId' => acctId,
                'country' => country, 'defaultCurrency' => cur
            });
        } catch (Exception e) { return err(e.getMessage()); }
    }
    
    @AuraEnabled
    public static String startWebhookConnectionTest(String webhookUrl) {
        try {
            if (String.isBlank(webhookUrl)) {
                return err('Webhook URL is required.');
            }

            Credentials credentials = getCredentials();

            if (
                credentials == null ||
                (
                    String.isBlank(credentials.secretKey) &&
                    String.isBlank(credentials.namedCredential)
                )
            ) {
                return err('Stripe credentials are not configured.');
            }

            String normalizedUrl = normalizeWebhookUrl(webhookUrl);

            /*
            * First ensure the exact URL is registered and enabled.
            */
            StripeService.ApiResponse endpointsResponse =
                StripeService.get(
                    '/v1/webhook_endpoints',
                    new Map<String, String>{
                        'limit' => '100'
                    }
                );

            if (!endpointsResponse.success) {
                return err(
                    'Unable to retrieve Stripe webhook endpoints: ' +
                    endpointsResponse.errorMessage
                );
            }

            Boolean endpointFound = false;
            Boolean endpointEnabled = false;
            Boolean customerCreatedEnabled = false;
            String endpointId;

            List<Object> endpoints =
                endpointsResponse.data != null
                    ? (List<Object>) endpointsResponse.data.get('data')
                    : null;

            if (endpoints != null) {
                for (Object endpointObject : endpoints) {
                    Map<String, Object> endpoint =
                        (Map<String, Object>) endpointObject;

                    String registeredUrl =
                        normalizeWebhookUrl(
                            String.valueOf(endpoint.get('url'))
                        );

                    if (
                        String.isNotBlank(registeredUrl) &&
                        registeredUrl.equalsIgnoreCase(normalizedUrl)
                    ) {
                        endpointFound = true;
                        endpointId = String.valueOf(endpoint.get('id'));

                        String endpointStatus =
                            String.valueOf(endpoint.get('status'));

                        endpointEnabled =
                            'enabled'.equalsIgnoreCase(endpointStatus);

                        Object enabledEventsObject =
                            endpoint.get('enabled_events');

                        if (enabledEventsObject instanceof List<Object>) {
                            List<Object> enabledEvents =
                                (List<Object>) enabledEventsObject;

                            for (Object eventName : enabledEvents) {
                                String configuredEvent =
                                    String.valueOf(eventName);

                                if (
                                    configuredEvent == '*' ||
                                    configuredEvent.equalsIgnoreCase(
                                        'customer.created'
                                    )
                                ) {
                                    customerCreatedEnabled = true;
                                    break;
                                }
                            }
                        }

                        break;
                    }
                }
            }

            if (!endpointFound) {
                return ok(new Map<String, Object>{
                    'connected' => false,
                    'pending' => false,
                    'status' => 'not_registered',
                    'message' =>
                        'The exact webhook URL is not registered in Stripe.'
                });
            }

            if (!endpointEnabled) {
                return ok(new Map<String, Object>{
                    'connected' => false,
                    'pending' => false,
                    'status' => 'disabled',
                    'endpointId' => endpointId,
                    'message' =>
                        'The webhook is registered in Stripe but is disabled.'
                });
            }

            if (!customerCreatedEnabled) {
                return ok(new Map<String, Object>{
                    'connected' => false,
                    'pending' => false,
                    'status' => 'test_event_not_enabled',
                    'endpointId' => endpointId,
                    'message' =>
                        'The webhook does not subscribe to customer.created. ' +
                        'Register the webhook again before running the test.'
                });
            }

            /*
            * Generate a unique token that will travel inside Stripe metadata.
            */
            String testToken =
                EncodingUtil.convertToHex(
                    Crypto.generateDigest(
                        'SHA-256',
                        Blob.valueOf(
                            UserInfo.getOrganizationId() +
                            ':' +
                            UserInfo.getUserId() +
                            ':' +
                            String.valueOf(Datetime.now().getTime()) +
                            ':' +
                            String.valueOf(Crypto.getRandomLong())
                        )
                    )
                );

            Datetime requestedAt = Datetime.now();

            Map<String, Object> customerBody =
                new Map<String, Object>{
                    'name' => 'Salesforce Webhook Health Check',
                    'description' =>
                        'Temporary customer created by Salesforce webhook health check',
                    'metadata' => new Map<String, Object>{
                        'salesforce_webhook_test' => 'true',
                        'salesforce_webhook_test_token' => testToken,
                        'salesforce_org_id' =>
                            UserInfo.getOrganizationId()
                    }
                };

            StripeService.ApiResponse customerResponse =
                StripeService.post(
                    '/v1/customers',
                    customerBody,
                    'webhook-test-' + testToken
                );

            if (!customerResponse.success) {
                return err(
                    'Unable to create Stripe webhook test event: ' +
                    customerResponse.errorMessage
                );
            }

            String customerId =
                customerResponse.data != null
                    ? String.valueOf(customerResponse.data.get('id'))
                    : customerResponse.stripeId;

            return ok(new Map<String, Object>{
                'connected' => false,
                'pending' => true,
                'status' => 'pending',
                'token' => testToken,
                'customerId' => customerId,
                'requestedAt' => requestedAt,
                'endpointId' => endpointId,
                'message' =>
                    'Stripe test event created. Waiting for webhook delivery.'
            });

        } catch (Exception e) {
            return err(e.getMessage());
        }
    }

    @AuraEnabled
    public static String checkWebhookConnectionTest(
        String testToken,
        String customerId,
        Datetime requestedAt,
        String webhookUrl
    ) {
        try {
            if (String.isBlank(testToken)) {
                return err('Webhook test token is required.');
            }

            Datetime searchFrom = requestedAt != null
                ? requestedAt.addMinutes(-1)
                : Datetime.now().addMinutes(-5);

            List<Stripe_Webhook_Log__c> logs = [
                SELECT
                    Id,
                    Event_Id__c,
                    Event_Type__c,
                    Payload__c,
                    Signature_Verified__c,
                    Processing_Status__c,
                    Error_Message__c,
                    CreatedDate
                FROM Stripe_Webhook_Log__c
                WHERE Event_Type__c = 'customer.created'
                AND CreatedDate >= :searchFrom
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];

            for (Stripe_Webhook_Log__c logRecord : logs) {
                if (String.isBlank(logRecord.Payload__c)) {
                    continue;
                }

                Map<String, Object> payload;

                try {
                    payload =
                        (Map<String, Object>)
                        JSON.deserializeUntyped(
                            logRecord.Payload__c
                        );
                } catch (Exception ignored) {
                    continue;
                }

                Map<String, Object> data =
                    payload.get('data') instanceof Map<String, Object>
                        ? (Map<String, Object>) payload.get('data')
                        : null;

                Map<String, Object> stripeObject =
                    data != null &&
                    data.get('object') instanceof Map<String, Object>
                        ? (Map<String, Object>) data.get('object')
                        : null;

                if (stripeObject == null) {
                    continue;
                }

                Map<String, Object> metadata =
                    stripeObject.get('metadata')
                        instanceof Map<String, Object>
                        ? (Map<String, Object>)
                            stripeObject.get('metadata')
                        : null;

                String receivedToken =
                    metadata != null
                        ? String.valueOf(
                            metadata.get(
                                'salesforce_webhook_test_token'
                            )
                        )
                        : null;

                if (receivedToken != testToken) {
                    continue;
                }

                Boolean signatureVerified =
                    logRecord.Signature_Verified__c == true;

                Boolean processingSucceeded =
                    String.isBlank(
                        logRecord.Processing_Status__c
                    ) ||
                    logRecord.Processing_Status__c
                        .equalsIgnoreCase('Processed') ||
                    logRecord.Processing_Status__c
                        .equalsIgnoreCase('Success') ||
                    logRecord.Processing_Status__c
                        .equalsIgnoreCase('Completed');

                if (!signatureVerified) {
                    return ok(new Map<String, Object>{
                        'connected' => false,
                        'pending' => false,
                        'status' => 'signature_failed',
                        'eventId' => logRecord.Event_Id__c,
                        'receivedAt' => logRecord.CreatedDate,
                        'message' =>
                            'Stripe reached Salesforce, but webhook signature verification failed.'
                    });
                }

                if (!processingSucceeded) {
                    return ok(new Map<String, Object>{
                        'connected' => false,
                        'pending' => false,
                        'status' => 'processing_failed',
                        'eventId' => logRecord.Event_Id__c,
                        'receivedAt' => logRecord.CreatedDate,
                        'message' =>
                            'Stripe reached Salesforce, but webhook processing failed: ' +
                            logRecord.Error_Message__c
                    });
                }

                /*
                * Optional cleanup of the temporary customer.
                */
                if (String.isNotBlank(customerId)) {
                    StripeService.del(
                        '/v1/customers/' +
                        EncodingUtil.urlEncode(
                            customerId,
                            'UTF-8'
                        )
                    );
                }

                return ok(new Map<String, Object>{
                    'connected' => true,
                    'pending' => false,
                    'status' => 'connected',
                    'eventId' => logRecord.Event_Id__c,
                    'receivedAt' => logRecord.CreatedDate,
                    'message' =>
                        'Webhook connection successful. Stripe delivered the event, ' +
                        'Salesforce verified the signature and processed the webhook.'
                });
            }

            Boolean timedOut =
                requestedAt != null &&
                requestedAt.addSeconds(10) < Datetime.now();

            if (timedOut) {
                return ok(new Map<String, Object>{
                    'connected' => false,
                    'pending' => false,
                    'status' => 'delivery_failed',
                    'webhookUrl' => webhookUrl,
                    'message' =>
                        'Webhook connection failed. The endpoint may be incorrect (HTTP 404) or unavailable. Check the Stripe Dashboard for the exact delivery error.'
                });
            }
            
            return ok(new Map<String, Object>{
                'connected' => false,
                'pending' => true,
                'status' => 'pending',
                'webhookUrl' => webhookUrl,
                'message' => 'Waiting for Stripe webhook delivery.'
            });

        } catch (Exception e) {
            return err(e.getMessage());
        }
    }

    private static String normalizeWebhookUrl(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        String normalized = value.trim();

        while (normalized.endsWith('/')) {
            normalized = normalized.substring(
                0,
                normalized.length() - 1
            );
        }

        return normalized;
    }

    /** Register this org's webhook endpoint in Stripe via the API and auto-save the
     *  returned signing secret to the active environment. */
    @AuraEnabled
    public static String registerWebhook(String webhookUrl) {
        try {
            Credentials c = getCredentials();
            if (c == null || (String.isBlank(c.secretKey) && String.isBlank(c.namedCredential))) {
                return err('Add your Stripe secret key first, then register.');
            }
            // String url = buildWebhookUrl(c);
            String url = String.isNotBlank(webhookUrl)
                ? webhookUrl.trim()
                : buildWebhookUrl(c);
            if (url.containsIgnoreCase('.my.salesforce.com')) {
                return err('The webhook URL points at the org login domain (not publicly reachable). Set the "Webhook Base URL" to your public Site (…my.site.com) and register again.');
            }
            // Remove any stale endpoints we previously created (avoids duplicates / the bad org-domain one).
            StripeService.ApiResponse existing = StripeService.get('/v1/webhook_endpoints', null);
            if (existing.success && existing.data != null) {
                List<Object> eps = (List<Object>) existing.data.get('data');
                if (eps != null) {
                    for (Object o : eps) {
                        Map<String, Object> ep = (Map<String, Object>) o;
                        String epUrl = String.valueOf(ep.get('url'));
                        if (epUrl != null && epUrl.contains('/services/apexrest/stripe/webhook')) {
                            StripeService.del('/v1/webhook_endpoints/' + ep.get('id'));
                        }
                    }
                }
            }
            Map<String, Object> body = new Map<String, Object>{
                'url' => url,
                'description' => 'Salesforce Stripe Connector',
                'enabled_events' => new List<Object>{
                    'customer.created',
                    // Checkout
                    'checkout.session.completed', 'checkout.session.expired',
                    'checkout.session.async_payment_succeeded', 'checkout.session.async_payment_failed',
                    // PaymentIntent lifecycle
                    'payment_intent.succeeded', 'payment_intent.payment_failed', 'payment_intent.canceled',
                    'payment_intent.processing', 'payment_intent.requires_action',
                    // Charge + refunds
                    'charge.succeeded', 'charge.captured', 'charge.failed', 'charge.pending',
                    'charge.expired', 'charge.refunded',
                    'refund.created', 'refund.updated', 'refund.failed', 'charge.refund.updated',
                    // Disputes
                    'charge.dispute.created', 'charge.dispute.closed',
                    'charge.dispute.funds_withdrawn', 'charge.dispute.funds_reinstated',
                    // Invoices (recurring)
                    'invoice.paid', 'invoice.payment_succeeded', 'invoice.payment_failed',
                    'invoice.payment_action_required', 'invoice.marked_uncollectible', 'invoice.voided',
                    // Subscriptions
                    'customer.subscription.created', 'customer.subscription.updated',
                    'customer.subscription.deleted', 'customer.subscription.paused',
                    'customer.subscription.resumed', 'customer.subscription.trial_will_end',
                    // SetupIntent (save card / mandate)
                    'setup_intent.succeeded', 'setup_intent.setup_failed'
                }
            };
            StripeService.ApiResponse r = StripeService.post('/v1/webhook_endpoints', body, null);
            if (!r.success) return err(r.errorMessage);

            String secret = r.data != null ? String.valueOf(r.data.get('secret')) : null;
            if (String.isNotBlank(secret)) {
                Stripe_Credentials__c cr = Stripe_Credentials__c.getOrgDefaults();
                if (cr == null || cr.Id == null) cr = new Stripe_Credentials__c(SetupOwnerId = UserInfo.getOrganizationId());
                if ('live'.equalsIgnoreCase(c.environment)) cr.Webhook_Signing_Secret_Live__c = secret;
                else cr.Webhook_Signing_Secret_Test__c = secret;
                upsert cr;
            }
            return ok(new Map<String, Object>{
                'message' => 'Webhook registered in Stripe and signing secret saved.',
                'endpointId' => r.stripeId, 'url' => url
            });
        } catch (Exception e) { return err(e.getMessage()); }
    }

    // ═══════════════════════ PAYMENT CONFIG ═══════════════════════

    public static PaymentConfig getConfig(String configName, String objectApiName) {
        if (String.isNotBlank(configName)) {
            Stripe_Payment_Config__c s = Stripe_Payment_Config__c.getInstance(configName);
            if (s != null && s.Is_Active__c) return mapConfig(s, configName);
        }
        if (String.isNotBlank(objectApiName)) {
            for (String n : Stripe_Payment_Config__c.getAll().keySet()) {
                Stripe_Payment_Config__c c = Stripe_Payment_Config__c.getAll().get(n);
                if (c.Is_Active__c && c.Source_Object__c == objectApiName) return mapConfig(c, n);
            }
        }
        return null;
    }

    @AuraEnabled(cacheable=false)
    public static String getAllConfigs() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        Map<String, Stripe_Payment_Config__c> all = Stripe_Payment_Config__c.getAll();
        for (String n : all.keySet()) {
            result.add(configToMap(all.get(n), n));
        }
        return JSON.serialize(result);
    }

    @AuraEnabled
    public static String getConfigByName(String configName) {
        try {
            Stripe_Payment_Config__c c = Stripe_Payment_Config__c.getInstance(configName);
            if (c == null) return err('Config not found.');
            return ok(new Map<String, Object>{ 'data' => configToMap(c, configName) });
        } catch (Exception e) { return err(e.getMessage()); }
    }

    @AuraEnabled
    public static String saveConfig(String configJson) {
        try {
            Map<String, Object> d = (Map<String, Object>) JSON.deserializeUntyped(configJson);
            String name = (String) d.get('Name');
            if (String.isBlank(name)) return err('Config name is required.');

            Stripe_Payment_Config__c existing = Stripe_Payment_Config__c.getInstance(name);
            Stripe_Payment_Config__c cfg = (existing != null && existing.Id != null)
                ? existing : new Stripe_Payment_Config__c(Name = name);

            cfg.Source_Object__c        = gs(d,'Source_Object');
            cfg.Checkout_Mode__c        = gs(d,'Checkout_Mode');
            cfg.Payment_Type__c         = gs(d,'Payment_Type');
            cfg.Amount_Field__c         = gs(d,'Amount_Field');
            cfg.Name_Field__c           = gs(d,'Name_Field');
            cfg.Email_Field__c          = gs(d,'Email_Field');
            cfg.Phone_Field__c          = gs(d,'Phone_Field');
            cfg.Product_Info_Field__c   = gs(d,'Product_Info');
            cfg.UDF1_Field__c  = gs(d,'UDF1');  cfg.UDF2_Field__c  = gs(d,'UDF2');
            cfg.UDF3_Field__c  = gs(d,'UDF3');  cfg.UDF4_Field__c  = gs(d,'UDF4');
            cfg.UDF5_Field__c  = gs(d,'UDF5');  cfg.UDF6_Field__c  = gs(d,'UDF6');
            cfg.UDF7_Field__c  = gs(d,'UDF7');  cfg.UDF8_Field__c  = gs(d,'UDF8');
            cfg.UDF9_Field__c  = gs(d,'UDF9');  cfg.UDF10_Field__c = gs(d,'UDF10');
            cfg.Price_Id__c             = gs(d,'Price_Id');
            cfg.Price_Id_Field__c       = gs(d,'Price_Id_Field');
            cfg.Allowed_Payment_Methods__c = gs(d,'Allowed_Payment_Methods');
            cfg.Currency__c             = gs(d,'Currency');
            cfg.Post_Success_Field__c   = gs(d,'Post_Success');
            cfg.Post_Success_Value__c   = gs(d,'Post_Value');
            cfg.Post_Success_Flow__c    = gs(d,'Post_Flow');
            cfg.QuickActionName__c      = gs(d,'QuickActionName');
            cfg.Payment_Options_Config__c = gs(d,'Payment_Options_Config');
            cfg.ValidationRuleConfig__c = gs(d,'ValidationRuleConfig');
            cfg.Trial_Days__c           = d.get('Trial_Days') != null ? Decimal.valueOf(String.valueOf(d.get('Trial_Days'))) : null;
            cfg.Allow_Promotion_Codes__c   = bool(d,'Allow_Promotion_Codes');
            cfg.Collect_Billing_Address__c = bool(d,'Collect_Billing_Address');
            cfg.Save_Payment_Method__c     = bool(d,'Save_Payment_Method');
            cfg.Guest_Enabled__c           = bool(d,'Guest_Enabled');
            cfg.Send_Notification__c   = d.get('Notification') != null ? Boolean.valueOf(d.get('Notification')) : true;
            cfg.Is_Active__c           = d.get('Is_Active') != null ? Boolean.valueOf(d.get('Is_Active')) : true;
            cfg.Expiry_Hours__c        = d.get('Expiry_Hours') != null ? Decimal.valueOf(String.valueOf(d.get('Expiry_Hours'))) : 72;

            upsert cfg;
            return ok(new Map<String, Object>{'message' => 'Config "'+name+'" saved.', 'id' => cfg.Id});
        } catch (Exception e) { return err(e.getMessage()); }
    }

    @AuraEnabled
    public static String deleteConfig(String configName) {
        try {
            Stripe_Payment_Config__c ex = Stripe_Payment_Config__c.getInstance(configName);
            if (ex == null || ex.Id == null) return err('Config not found.');
            delete ex;
            return ok(new Map<String, Object>{'message' => 'Deleted.'});
        } catch (Exception e) { return err(e.getMessage()); }
    }

    // ───── LWC entry: resolve config + source-record values ─────

    @AuraEnabled
    public static String getConfigWithRecordValues(Id recordId, String objectApiName, String configName) {
        try {
            String objName = String.isNotBlank(objectApiName)
                ? objectApiName
                : (recordId != null ? recordId.getSObjectType().getDescribe().getName() : null);

            Stripe_Payment_Config__c raw = null;
            String detected = null;

            if (String.isNotBlank(configName)) {
                Stripe_Payment_Config__c c = Stripe_Payment_Config__c.getInstance(configName);
                if (c != null && c.Is_Active__c) { raw = c; detected = configName; }
                if (detected == null) {
                    for (String n : Stripe_Payment_Config__c.getAll().keySet()) {
                        c = Stripe_Payment_Config__c.getAll().get(n);
                        if (c.Is_Active__c && c.QuickActionName__c == configName) { raw = c; detected = n; break; }
                    }
                }
            }
            if (detected == null && String.isNotBlank(objName)) {
                for (String n : Stripe_Payment_Config__c.getAll().keySet()) {
                    Stripe_Payment_Config__c c = Stripe_Payment_Config__c.getAll().get(n);
                    if (c.Is_Active__c && c.Source_Object__c == objName) { raw = c; detected = n; break; }
                }
            }
            if (raw == null) {
                return err('No active Stripe Payment Config found for object: ' + objName);
            }

            Map<String, String> encodedFields = new Map<String, String>{
                'Amount_Field' => raw.Amount_Field__c, 'Name_Field' => raw.Name_Field__c,
                'Email_Field' => raw.Email_Field__c, 'Phone_Field' => raw.Phone_Field__c,
                'Product_Info' => raw.Product_Info_Field__c,
                'UDF1' => raw.UDF1_Field__c, 'UDF2' => raw.UDF2_Field__c, 'UDF3' => raw.UDF3_Field__c,
                'UDF4' => raw.UDF4_Field__c, 'UDF5' => raw.UDF5_Field__c, 'UDF6' => raw.UDF6_Field__c,
                'UDF7' => raw.UDF7_Field__c, 'UDF8' => raw.UDF8_Field__c, 'UDF9' => raw.UDF9_Field__c,
                'UDF10' => raw.UDF10_Field__c
            };

            Map<String, Object> fieldValues = new Map<String, Object>();
            SObject rec = null;

            if (recordId != null && String.isNotBlank(objName)) {
                Map<String, Schema.SObjectField> fieldMap =
                    Schema.getGlobalDescribe().get(objName)?.getDescribe().fields.getMap();

                Set<String> selectFields = new Set<String>{ 'Id' };
                Map<String, String> keyToPath = new Map<String, String>();

                for (String fk : encodedFields.keySet()) {
                    FieldConfig cfg = decodeFieldConfig(encodedFields.get(fk));
                    if (cfg.sourceType != 'FIELD' || String.isBlank(cfg.value)) continue;
                    String path = cfg.value.trim();
                    keyToPath.put(fk, path);
                    if (fieldMap == null) continue;
                    if (path.contains('.')) {
                        String relSeg = path.split('\\.')[0].toLowerCase();
                        for (String mk : fieldMap.keySet()) {
                            Schema.DescribeFieldResult dfr = fieldMap.get(mk).getDescribe();
                            if (dfr.getType() == Schema.DisplayType.REFERENCE
                                && dfr.getRelationshipName() != null
                                && dfr.getRelationshipName().toLowerCase() == relSeg) {
                                selectFields.add(path); break;
                            }
                        }
                    } else if (fieldMap.containsKey(path.toLowerCase())
                               && fieldMap.get(path.toLowerCase()).getDescribe().isAccessible()) {
                        selectFields.add(path);
                    } else {
                        keyToPath.remove(fk);
                    }
                }

                if (selectFields.size() > 1) {
                    String soql = 'SELECT ' + String.join(new List<String>(selectFields), ', ')
                        + ' FROM ' + String.escapeSingleQuotes(objName)
                        + ' WHERE Id = :recordId LIMIT 1';
                    List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE);
                    rec = rows.isEmpty() ? null : rows[0];
                }

                for (String fk : encodedFields.keySet()) {
                    FieldConfig cfg = decodeFieldConfig(encodedFields.get(fk));
                    if (cfg.sourceType == 'FIELD') {
                        Object v = (keyToPath.containsKey(fk)) ? getFieldVal(rec, keyToPath.get(fk)) : null;
                        fieldValues.put(fk, v != null ? String.valueOf(v) : '');
                    } else if (cfg.sourceType == 'HARDCODED') {
                        String v = cfg.value;
                        if (v != null && v.contains('{RecordId}')) v = v.replace('{RecordId}', String.valueOf(recordId));
                        fieldValues.put(fk, v != null ? v : '');
                    } else {
                        fieldValues.put(fk, '');
                    }
                }
            }

            Map<String, Object> configMap = new Map<String, Object>{
                'configName' => detected,
                'checkoutMode' => raw.Checkout_Mode__c,
                'paymentType' => raw.Payment_Type__c,
                'priceId' => raw.Price_Id__c,
                'trialDays' => raw.Trial_Days__c,
                'allowPromotionCodes' => raw.Allow_Promotion_Codes__c,
                'collectBillingAddress' => raw.Collect_Billing_Address__c,
                'savePaymentMethod' => raw.Save_Payment_Method__c,
                'guestEnabled' => raw.Guest_Enabled__c,
                'currency' => raw.Currency__c,
                'sendNotification' => raw.Send_Notification__c,
                'Payment_Options_Config' => raw.Payment_Options_Config__c,
                'ValidationRuleConfig' => raw.ValidationRuleConfig__c
            };
            for (String k : encodedFields.keySet()) configMap.put(k, encodedFields.get(k));

            return JSON.serialize(new Map<String, Object>{
                'success' => true, 'config' => configMap, 'fieldValues' => fieldValues
            });
        } catch (Exception e) { return err(e.getMessage()); }
    }

    // ───────────────────────── Helpers ─────────────────────────

    private static PaymentConfig mapConfig(Stripe_Payment_Config__c c, String name) {
        PaymentConfig p = new PaymentConfig();
        p.configName = name; p.sourceObject = c.Source_Object__c; p.checkoutMode = c.Checkout_Mode__c;
        p.paymentType = c.Payment_Type__c; p.amountField = c.Amount_Field__c; p.nameField = c.Name_Field__c;
        p.emailField = c.Email_Field__c; p.phoneField = c.Phone_Field__c; p.productInfoField = c.Product_Info_Field__c;
        p.priceId = c.Price_Id__c; p.priceIdField = c.Price_Id_Field__c;
        p.trialDays = c.Trial_Days__c != null ? Integer.valueOf(c.Trial_Days__c) : null;
        p.allowPromotionCodes = c.Allow_Promotion_Codes__c; p.collectBillingAddress = c.Collect_Billing_Address__c;
        p.savePaymentMethod = c.Save_Payment_Method__c; p.guestEnabled = c.Guest_Enabled__c;
        p.allowedPaymentMethods = c.Allowed_Payment_Methods__c; p.currencyCode = c.Currency__c;
        p.postSuccessField = c.Post_Success_Field__c; p.postSuccessValue = c.Post_Success_Value__c;
        p.postSuccessFlow = c.Post_Success_Flow__c; p.sendNotification = c.Send_Notification__c;
        p.isActive = c.Is_Active__c;
        p.udfFields = new List<String>{ c.UDF1_Field__c, c.UDF2_Field__c, c.UDF3_Field__c, c.UDF4_Field__c,
            c.UDF5_Field__c, c.UDF6_Field__c, c.UDF7_Field__c, c.UDF8_Field__c, c.UDF9_Field__c, c.UDF10_Field__c };
        return p;
    }

    private static Map<String, Object> configToMap(Stripe_Payment_Config__c c, String name) {
        return new Map<String, Object>{
            'Name'=>name, 'Source_Object'=>c.Source_Object__c, 'Checkout_Mode'=>c.Checkout_Mode__c,
            'Payment_Type'=>c.Payment_Type__c, 'Amount_Field'=>c.Amount_Field__c, 'Name_Field'=>c.Name_Field__c,
            'Email_Field'=>c.Email_Field__c, 'Phone_Field'=>c.Phone_Field__c, 'Product_Info'=>c.Product_Info_Field__c,
            'Price_Id'=>c.Price_Id__c, 'Price_Id_Field'=>c.Price_Id_Field__c, 'Trial_Days'=>c.Trial_Days__c,
            'Allow_Promotion_Codes'=>c.Allow_Promotion_Codes__c, 'Collect_Billing_Address'=>c.Collect_Billing_Address__c,
            'Save_Payment_Method'=>c.Save_Payment_Method__c, 'Guest_Enabled'=>c.Guest_Enabled__c,
            'Allowed_Payment_Methods'=>c.Allowed_Payment_Methods__c, 'Currency'=>c.Currency__c,
            'Post_Success'=>c.Post_Success_Field__c, 'Post_Value'=>c.Post_Success_Value__c, 'Post_Flow'=>c.Post_Success_Flow__c,
            'QuickActionName'=>c.QuickActionName__c, 'Payment_Options_Config'=>c.Payment_Options_Config__c,
            'ValidationRuleConfig'=>c.ValidationRuleConfig__c, 'Notification'=>c.Send_Notification__c,
            'Is_Active'=>c.Is_Active__c, 'Expiry_Hours'=>c.Expiry_Hours__c,
            'UDF1'=>c.UDF1_Field__c,'UDF2'=>c.UDF2_Field__c,'UDF3'=>c.UDF3_Field__c,'UDF4'=>c.UDF4_Field__c,'UDF5'=>c.UDF5_Field__c,
            'UDF6'=>c.UDF6_Field__c,'UDF7'=>c.UDF7_Field__c,'UDF8'=>c.UDF8_Field__c,'UDF9'=>c.UDF9_Field__c,'UDF10'=>c.UDF10_Field__c
        };
    }

    public class FieldConfig {
        public String sourceType;
        public String value;
        public Boolean visible;
        public Boolean required;
        public Boolean readOnly;
        public String label;
        public Boolean passToGateway;
    }

    /** Decode pipe string: sourceType|value|visible|required|readOnly|label|order|passToGateway */
    public static FieldConfig decodeFieldConfig(String raw) {
        FieldConfig cfg = new FieldConfig();
        cfg.visible = true; cfg.required = false; cfg.readOnly = false;
        cfg.label = ''; cfg.value = ''; cfg.sourceType = 'BLANK'; cfg.passToGateway = false;
        if (String.isBlank(raw)) return cfg;
        if (!raw.contains('|')) { cfg.sourceType = 'FIELD'; cfg.value = raw.trim(); return cfg; }
        List<String> p = raw.split('\\|', 8);
        cfg.sourceType    = p.size() > 0 ? p[0] : '';
        cfg.value         = p.size() > 1 ? p[1] : '';
        cfg.visible       = p.size() > 2 ? p[2] != 'false' : true;
        cfg.required      = p.size() > 3 ? p[3] == 'true' : false;
        cfg.readOnly      = p.size() > 4 ? p[4] == 'true' : false;
        cfg.label         = p.size() > 5 ? p[5] : '';
        cfg.passToGateway = p.size() > 7 ? p[7] == 'true' : false;
        return cfg;
    }

    private static Object getFieldVal(SObject rec, String fieldPath) {
        if (rec == null || String.isBlank(fieldPath)) return null;
        try {
            List<String> parts = fieldPath.trim().split('\\.');
            SObject cur = rec;
            for (Integer i = 0; i < parts.size() - 1; i++) {
                cur = cur.getSObject(parts[i]);
                if (cur == null) return null;
            }
            return cur.get(parts[parts.size() - 1]);
        } catch (Exception e) { return null; }
    }

    /** Webhook delivery URL — public Site base if configured, else the org domain. */
    private static final String WEBHOOK_PATH =
        '/services/apexrest/acxitech/stripe/webhook';

    private static String buildWebhookUrl(
        Credentials c
    ) {
       
        if (
            c == null ||
            String.isBlank(c.webhookBaseUrl)
        ) {
            return null;
        }

        String base =
            c.webhookBaseUrl.trim();

        if (
            !base.startsWithIgnoreCase(
                'https://'
            ) &&
            !base.startsWithIgnoreCase(
                'http://'
            )
        ) {
            base = 'https://' + base;
        }

        while (base.endsWith('/')) {
            base = base.substring(
                0,
                base.length() - 1
            );
        }

        return base + WEBHOOK_PATH;
    }

    @AuraEnabled(cacheable=true)
    public static String getDefaultWebhookBaseUrl() {
    
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
    
        if (orgUrl.endsWith('.my.salesforce.com')) {
            return orgUrl.replace('.my.salesforce.com', '.my.site.com');
        }
    
        return orgUrl;
    }

    private static String mask(String s) {
        if (String.isBlank(s) || s.length() < 8) return '****';
        return s.substring(0, 7) + '…' + s.substring(s.length() - 4);
    }
    private static String gs(Map<String,Object> d, String k) { Object v = d.get(k); return v != null ? String.valueOf(v) : null; }
    private static Boolean bool(Map<String,Object> d, String k) { Object v = d.get(k); return v != null && Boolean.valueOf(v); }
    private static String ok(Map<String,Object> extra) { Map<String,Object> m = new Map<String,Object>{'success'=>true}; m.putAll(extra); return JSON.serialize(m); }
    private static String err(String m) { return JSON.serialize(new Map<String,Object>{'success'=>false,'message'=>m}); }
}