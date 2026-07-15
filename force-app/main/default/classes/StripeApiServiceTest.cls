@isTest
private class StripeApiServiceTest {

    @isTest static void encodeForm_bracketNotation() {
        Map<String, Object> body = new Map<String, Object>{
            'mode' => 'payment',
            'line_items' => new List<Object>{ new Map<String, Object>{ 'price' => 'price_1', 'quantity' => 2 } },
            'metadata' => new Map<String, Object>{ 'udf1' => 'x' }
        };
        String encoded = StripeApiService.encodeFormPublic(body);
        System.assert(encoded.contains('mode=payment'), encoded);
        System.assert(encoded.contains(EncodingUtil.urlEncode('line_items[0][price]', 'UTF-8') + '=price_1'), encoded);
        System.assert(encoded.contains(EncodingUtil.urlEncode('line_items[0][quantity]', 'UTF-8') + '=2'), encoded);
        System.assert(encoded.contains(EncodingUtil.urlEncode('metadata[udf1]', 'UTF-8') + '=x'), encoded);
    }

    @isTest static void callout_success() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        StripeApiService.ApiResponse r = StripeApiService.callout('CHECKOUT_SESSION_CREATE',
            new Map<String, Object>{ 'mode' => 'payment' }, 'idem_1');
        Test.stopTest();
        System.assert(r.success, r.errorMessage);
        System.assertEquals('cs_test_123', r.stripeId);
    }

    @isTest static void callout_getWithPathParam() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        StripeApiService.ApiResponse r = StripeApiService.callout('CHECKOUT_SESSION_GET',
            new Map<String, String>{ 'id' => 'cs_test_123' }, null, null);
        Test.stopTest();
        System.assert(r.success);
    }

    @isTest static void callout_unknownOperation() {
        StripeTestDataFactory.setupCredentials();
        Test.startTest();
        StripeApiService.ApiResponse r = StripeApiService.callout('NOPE', new Map<String, Object>(), null);
        Test.stopTest();
        System.assert(!r.success);
        System.assert(r.errorMessage.contains('Unknown Stripe operation'));
    }

    @isTest static void callout_noCredentials() {
        Test.startTest();
        StripeApiService.ApiResponse r = StripeApiService.callout('CUSTOMER_CREATE', new Map<String, Object>(), null);
        Test.stopTest();
        System.assert(!r.success);
        System.assert(r.errorMessage.contains('secret key'));
    }

    @isTest static void callout_stripeError() {
        StripeTestDataFactory.setupCredentials();
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock(402, true));
        Test.startTest();
        StripeApiService.ApiResponse r = StripeApiService.callout('PAYMENT_INTENT_CREATE',
            new Map<String, Object>{ 'amount' => 100 }, null);
        Test.stopTest();
        System.assert(!r.success);
        System.assert(r.errorMessage.contains('declined'), r.errorMessage);
    }

    @isTest static void registry_listed() {
        System.assert(!StripeApiService.getApiRegistry().isEmpty());
    }
}