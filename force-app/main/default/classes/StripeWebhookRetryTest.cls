@isTest
private class StripeWebhookRetryTest {

    @isTest static void retry_reprocessesFailedVerifiedEvent() {
        StripeTestDataFactory.setupCredentials();
        Stripe_Payment__c p = new Stripe_Payment__c(Payment_Intent_Id__c = 'pi_retry', Status__c = 'Initiated');
        insert p;
        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_retry', Event_Type__c = 'payment_intent.succeeded',
            Signature_Verified__c = true, Processing_Status__c = 'Error',
            Payload__c = '{"id":"evt_retry","type":"payment_intent.succeeded","data":{"object":{"id":"pi_retry","status":"succeeded"}}}');

        Test.startTest();
        String res = StripeWebhookRetry.retryFailedLWC();
        Test.stopTest();

        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
        System.assertEquals('Completed', [SELECT Status__c FROM Stripe_Payment__c WHERE Id = :p.Id].Status__c);
        System.assertEquals('Processed', [SELECT Processing_Status__c FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_retry'].Processing_Status__c);
    }

    @isTest static void retry_malformedPayload_capturesError() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_bad_retry', Event_Type__c = 'payment_intent.succeeded',
            Signature_Verified__c = true, Processing_Status__c = 'Error',
            Payload__c = 'this-is-not-json');
        Test.startTest();
        Integer n = StripeWebhookRetry.retryFailed(50);
        Test.stopTest();
        System.assertEquals(1, n);
        Stripe_Webhook_Log__c log = [SELECT Processing_Status__c, Error_Message__c FROM Stripe_Webhook_Log__c WHERE Event_Id__c = 'evt_bad_retry'];
        System.assertEquals('Error', log.Processing_Status__c, 'still Error — reprocess threw on bad JSON');
        System.assert(log.Error_Message__c != null && log.Error_Message__c.startsWith('Retry failed'), 'error captured: ' + log.Error_Message__c);
    }

    @isTest static void retry_blankPayload_skipped() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_blank_retry', Event_Type__c = 'payment_intent.succeeded',
            Signature_Verified__c = true, Processing_Status__c = 'Error', Payload__c = '');
        Test.startTest();
        Integer n = StripeWebhookRetry.retryFailed(50);
        Test.stopTest();
        System.assertEquals(0, n, 'blank-payload logs are skipped, not updated');
    }

    @isTest static void retry_schedulable() {
        StripeTestDataFactory.setupCredentials();
        Test.startTest();
        System.schedule('StripeRetryTest', '0 0 1 * * ?', new StripeWebhookRetry());
        Test.stopTest();
        System.assertEquals(0, StripeWebhookRetry.retryFailed(10));
    }
}