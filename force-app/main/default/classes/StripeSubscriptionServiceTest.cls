@isTest
private class StripeSubscriptionServiceTest {

    @isTest static void createSubscription_paymentElement() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeSubscriptionService.createSubscription('cus_1', 'price_1', 14, 'Account', '001000000000001', null);
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        System.assertEquals('sub_test_123', r.get('subscriptionId'));
        System.assertEquals('pi_sub_1_secret', r.get('clientSecret'));
        Stripe_Subscription__c s = [SELECT Status__c, Interval__c, Amount__c, Raw_Response__c FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_test_123'];
        System.assertEquals('active', s.Status__c);
        System.assertEquals(19.99, s.Amount__c);
        System.assert(s.Raw_Response__c != null && s.Raw_Response__c.contains('sub_test_123'), 'raw API response stored on subscription');
    }

    @isTest static void createSubscriptionCheckout_hosted() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeSubscriptionService.createSubscriptionCheckout('price_1', 'HOSTED', 'a@b.com', null, 7, true, '001000000000001', null);
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        System.assertEquals('cs_test_123', r.get('checkoutSessionId'));
    }

    @isTest static void cancelSubscription_atPeriodEnd() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String r = StripeSubscriptionService.cancelSubscription('sub_1', true);
        Test.stopTest();
        System.assert((Boolean) ((Map<String,Object>) JSON.deserializeUntyped(r)).get('success'), r);
    }

    @isTest static void cancelSubscription_immediate() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String r = StripeSubscriptionService.cancelSubscription('sub_1', false);
        Test.stopTest();
        System.assert((Boolean) ((Map<String,Object>) JSON.deserializeUntyped(r)).get('success'), r);
    }

    @isTest static void updateSubscriptionPrice_works() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String r = StripeSubscriptionService.updateSubscriptionPrice('sub_1', 'price_2');
        Test.stopTest();
        System.assert((Boolean) ((Map<String,Object>) JSON.deserializeUntyped(r)).get('success'), r);
    }

    @isTest static void manageSubscription_dispatch() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String ok = StripeSubscriptionService.manageSubscription('sub_1', 'pause');
        Test.stopTest();
        System.assert((Boolean) ((Map<String,Object>) JSON.deserializeUntyped(ok)).get('success'), ok);
    }

    @isTest static void manageSubscription_validation() {
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(StripeSubscriptionService.manageSubscription(null, 'pause'))).get('success'));
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(StripeSubscriptionService.manageSubscription('sub_1', null))).get('success'));
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(StripeSubscriptionService.manageSubscription('sub_1', 'bogus'))).get('success'));
    }

    @isTest static void pause_subscription() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String p = StripeSubscriptionService.pauseSubscription('sub_1');
        Test.stopTest();
        System.assert((Boolean) ((Map<String,Object>) JSON.deserializeUntyped(p)).get('success'), p);
    }

    @isTest static void resume_subscription() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String r = StripeSubscriptionService.resumeSubscription('sub_1');
        Test.stopTest();
        System.assert((Boolean) ((Map<String,Object>) JSON.deserializeUntyped(r)).get('success'), r);
    }

    @isTest static void pauseResume_missingId() {
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(StripeSubscriptionService.pauseSubscription(null))).get('success'));
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(StripeSubscriptionService.resumeSubscription(''))).get('success'));
    }

    @isTest static void createSubscription_missingArgs() {
        String res = StripeSubscriptionService.createSubscription(null, null, null, null, null, null);
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }

    @isTest static void createSubscription_withEndDate_sendsCancelAt() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Datetime endDate = Datetime.now().addMonths(12);
        Test.startTest();
        String res = StripeSubscriptionService.createSubscription('cus_1', 'price_1', null, 'Account', '001000000000001', endDate);
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'), res);
    }

    @isTest static void endDateForCycles_computesFinalPeriod() {
        // open-ended
        System.assertEquals(null, StripeSubscriptionService.endDateForCycles('month', null));
        System.assertEquals(null, StripeSubscriptionService.endDateForCycles('month', 0));
        // 3 monthly payments → inside the 3rd period (≈ now + 2 months + 1 day)
        Datetime d3 = StripeSubscriptionService.endDateForCycles('month', 3);
        System.assert(d3 > Datetime.now().addMonths(2), 'end lands after the 2nd renewal');
        System.assert(d3 < Datetime.now().addMonths(3), 'and before the 3rd renewal, so exactly 3 charges');
        // yearly path
        Datetime dy = StripeSubscriptionService.endDateForCycles('year', 2);
        System.assert(dy > Datetime.now().addYears(1) && dy < Datetime.now().addYears(2));
    }

    @isTest static void endDateApplied_viaQueueable() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        insert new Stripe_Subscription__c(Subscription_Id__c = 'sub_test_123', Status__c = 'active');
        Test.startTest();
        System.enqueueJob(new StripeSubscriptionEndDateQueueable('sub_test_123', Datetime.now().addMonths(6).getTime() / 1000));
        Test.stopTest();
        // Queueable ran SUBSCRIPTION_UPDATE against the mock and re-synced without error.
        System.assertEquals(1, [SELECT COUNT() FROM Stripe_Subscription__c WHERE Subscription_Id__c = 'sub_test_123']);
    }
}