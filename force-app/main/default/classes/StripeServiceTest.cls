@isTest
private class StripeServiceTest {

    @isTest static void makeApiCall_post() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        StripeService.ApiResponse r = StripeService.post('/v1/customers',
            new Map<String, Object>{ 'email' => 'a@b.com' }, 'idem_x');
        Test.stopTest();
        System.assert(r.success, r.errorMessage);
        System.assertEquals('cus_test_123', r.stripeId);
    }

    @isTest static void makeApiCall_getWithQuery() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        StripeService.ApiResponse r = StripeService.get('/v1/customers/search',
            new Map<String, String>{ 'query' => 'email:\'a@b.com\'' });
        Test.stopTest();
        System.assert(r.success);
    }

    @isTest static void callByType_andDelete() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        StripeService.ApiResponse r1 = StripeService.callByType('REFUND_CREATE',
            new Map<String, Object>{ 'payment_intent' => 'pi_1' }, 'idem_r');
        StripeService.ApiResponse r2 = StripeService.callByType('SUBSCRIPTION_CANCEL',
            new Map<String, String>{ 'id' => 'sub_1' }, null, null);
        StripeService.ApiResponse r3 = StripeService.del('/v1/subscriptions/sub_1');
        Test.stopTest();
        System.assert(r1.success);
        System.assert(r2.success);
        System.assert(r3.success);
    }

    @isTest static void makeApiCall_noCredentials() {
        Test.startTest();
        StripeService.ApiResponse r = StripeService.post('/v1/customers', new Map<String, Object>(), null);
        Test.stopTest();
        System.assert(!r.success);
    }
}