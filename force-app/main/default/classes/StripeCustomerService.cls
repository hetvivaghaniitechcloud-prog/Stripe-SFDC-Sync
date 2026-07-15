/**
 * StripeCustomerService — find-or-create Stripe Customers and build Customer
 * Portal sessions. Customers are reused (idempotent) on email / Salesforce Id
 * stored in customer metadata.
 */
public with sharing class StripeCustomerService {

    /** Find an existing customer by email, else create one. Returns the cus_… id. */
    public static String findOrCreateCustomer(String email, String name, String sfRecordId) {
        if (String.isNotBlank(email)) {
            String found = searchByEmail(email);
            if (String.isNotBlank(found)) return found;
        }
        Map<String, Object> body = new Map<String, Object>();
        if (String.isNotBlank(email)) body.put('email', email);
        if (String.isNotBlank(name)) body.put('name', name);
        if (String.isNotBlank(sfRecordId)) {
            body.put('metadata', new Map<String, Object>{ 'sf_record_id' => sfRecordId });
        }
        String idem = 'cust_' + (String.isNotBlank(sfRecordId) ? sfRecordId : (email != null ? email : 'anon'));
        StripeApiService.ApiResponse r = StripeApiService.callout('CUSTOMER_CREATE', body, idem);
        return r.success ? r.stripeId : null;
    }

    private static String searchByEmail(String email) {
        Map<String, Object> q = new Map<String, Object>{ 'query' => 'email:\'' + email + '\'' };
        StripeApiService.ApiResponse r = StripeApiService.callout('CUSTOMER_SEARCH', q, null);
        if (!r.success || r.data == null) return null;
        Object data = r.data.get('data');
        if (data instanceof List<Object> && !((List<Object>) data).isEmpty()) {
            Map<String, Object> first = (Map<String, Object>) ((List<Object>) data)[0];
            return String.valueOf(first.get('id'));
        }
        return null;
    }

    @AuraEnabled
    public static String findOrCreateCustomerLWC(String email, String name, String sfRecordId) {
        try {
            String id = findOrCreateCustomer(email, name, sfRecordId);
            return JSON.serialize(new Map<String, Object>{ 'success' => id != null, 'customerId' => id });
        } catch (Exception e) {
            return JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() });
        }
    }

    /** Self-service Customer Portal session for managing subscriptions / methods. */
    @AuraEnabled
    public static String createBillingPortalSession(String customerId, String returnUrl) {
        try {
            if (String.isBlank(customerId)) {
                return JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => 'customerId is required.' });
            }
            Map<String, Object> body = new Map<String, Object>{ 'customer' => customerId };
            if (String.isNotBlank(returnUrl)) body.put('return_url', returnUrl);
            StripeApiService.ApiResponse r = StripeApiService.callout('BILLING_PORTAL_CREATE', body, null);
            return JSON.serialize(new Map<String, Object>{
                'success' => r.success, 'url' => r.hostedUrl, 'message' => r.errorMessage
            });
        } catch (Exception e) {
            return JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() });
        }
    }
}