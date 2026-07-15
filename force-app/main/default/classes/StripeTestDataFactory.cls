/**
 * StripeTestDataFactory — shared test setup for the Stripe connector.
 */
@isTest
public class StripeTestDataFactory {

    public static final String WEBHOOK_SECRET = 'whsec_testsecret_abc123';

    /** Insert org-default credentials with a named credential + publishable key + webhook secret. */
    public static Stripe_Credentials__c setupCredentials() {
        Stripe_Credentials__c c = new Stripe_Credentials__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Environment__c = 'test',
            Publishable_Key_Test__c = 'pk_test_123',
            Secret_Key_Test__c = 'sk_test_123',
            Webhook_Signing_Secret_Test__c = WEBHOOK_SECRET,
            Stripe_Api_Version__c = '2024-06-20',
            Hosted_Enabled__c = true,
            Embedded_Enabled__c = true,
            Custom_Element_Enabled__c = true,
            Success_Url__c = 'https://example.com/success',
            Cancel_Url__c = 'https://example.com/cancel',
            Return_Url__c = 'https://example.com/return',
            Api_Timeout__c = 30000
        );
        insert c;
        return c;
    }

    /** Insert a payment config for a given object. */
    public static Stripe_Payment_Config__c setupConfig(String name, String sourceObject, String mode) {
        Stripe_Payment_Config__c cfg = new Stripe_Payment_Config__c(
            Name = name,
            Source_Object__c = sourceObject,
            Checkout_Mode__c = mode,
            Payment_Type__c = 'One-Time',
            Amount_Field__c = 'FIELD|AnnualRevenue|true|false|false|Amount|1|true',
            Name_Field__c = 'FIELD|Name|true|false|false|Name|2|true',
            Currency__c = 'usd',
            Is_Active__c = true,
            Send_Notification__c = false
        );
        insert cfg;
        return cfg;
    }

    public static Account makeAccount() {
        Account a = new Account(Name = 'Test Co', AnnualRevenue = 250);
        insert a;
        return a;
    }

    /** Build a valid Stripe-Signature header for a payload using the given secret. */
    public static String signPayload(String payload, String secret, Long tsEpoch) {
        String signedPayload = tsEpoch + '.' + payload;
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(signedPayload), Blob.valueOf(secret));
        String sig = EncodingUtil.convertToHex(mac);
        return 't=' + tsEpoch + ',v1=' + sig;
    }
}