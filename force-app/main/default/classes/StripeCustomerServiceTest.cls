@isTest
private class StripeCustomerServiceTest {

    @isTest static void findOrCreate_searchHit() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String id = StripeCustomerService.findOrCreateCustomer('a@b.com', 'Jane', '001x');
        Test.stopTest();
        System.assertEquals('cus_test_123', id);
    }

    @isTest static void findOrCreate_createWhenNoEmail() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String id = StripeCustomerService.findOrCreateCustomer(null, 'Jane', '001x');
        Test.stopTest();
        System.assertEquals('cus_test_123', id);
    }

    @isTest static void findOrCreateLWC_wrapsResult() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeCustomerService.findOrCreateCustomerLWC('a@b.com', 'Jane', '001x');
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }

    @isTest static void billingPortal_session() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String res = StripeCustomerService.createBillingPortalSession('cus_1', 'https://example.com/back');
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(res);
        System.assertEquals(true, r.get('success'), res);
        System.assertEquals('https://billing.stripe.com/p/session/test_123', r.get('url'));
    }

    @isTest static void billingPortal_missingCustomer() {
        String res = StripeCustomerService.createBillingPortalSession(null, null);
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(res)).get('success'));
    }
}