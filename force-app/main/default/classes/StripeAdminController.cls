/**
 * StripeAdminController — read methods for the Stripe Setup console (stripeApp).
 * All SOQL runs WITH USER_MODE so the admin's FLS/CRUD is enforced.
 */
public with sharing class StripeAdminController {

    @AuraEnabled(cacheable=true)
    public static List<Stripe_Payment__c> getRecentPayments() {
        return [
            SELECT Id, Name, Amount__c, Currency__c, Status__c, Checkout_Mode__c, Payment_Type__c,
                   Customer_Email__c, Config_Name__c, Checkout_Session_Id__c, Payment_Intent_Id__c, CreatedDate
            FROM Stripe_Payment__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Stripe_Subscription__c> getRecentSubscriptions() {
        return [
            SELECT Id, Name, Subscription_Id__c, Status__c, Interval__c, Amount__c, Currency__c,
                   Customer_Id__c, Current_Period_End__c, Cancel_At_Period_End__c, CreatedDate
            FROM Stripe_Subscription__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Stripe_Webhook_Log__c> getRecentWebhookLogs() {
        return [
            SELECT Id, Name, Event_Id__c, Event_Type__c, Signature_Verified__c,
                   Processing_Status__c, CreatedDate
            FROM Stripe_Webhook_Log__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    /** Accessible fields of an object, as {label, value} for the field-mapping pickers. */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectApiName) {
        List<Map<String, String>> out = new List<Map<String, String>>();
        if (String.isBlank(objectApiName)) return out;
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
        if (t == null) return out;
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();
        List<String> apis = new List<String>(fmap.keySet());
        apis.sort();
        for (String a : apis) {
            Schema.DescribeFieldResult d = fmap.get(a).getDescribe();
            if (!d.isAccessible()) continue;
            out.add(new Map<String, String>{ 'label' => d.getLabel() + ' (' + d.getName() + ')', 'value' => d.getName() });
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getSObjectNames() {
        List<String> names = new List<String>();
        for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult d = t.getDescribe();
            if (d.isCreateable() && d.isQueryable() && !d.isCustomSetting() && d.getName().endsWithIgnoreCase('__c') == false) {
                names.add(d.getName());
            } else if (d.isCreateable() && d.isQueryable() && d.isCustom() && !d.isCustomSetting()) {
                names.add(d.getName());
            }
        }
        names.sort();
        return names;
    }
}