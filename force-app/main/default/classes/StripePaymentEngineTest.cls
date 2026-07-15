@isTest
private class StripePaymentEngineTest {

    @isTest static void hosted_createsSessionAndPayment() {
        StripeTestDataFactory.setupCredentials();
        StripeTestDataFactory.setupConfig('AcctHosted', 'Account', 'HOSTED');
        Account a = StripeTestDataFactory.makeAccount();

        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String resJson = StripePaymentEngine.initiatePaymentLWC(
            a.Id, 50, 'usd', 'Jane', 'jane@example.com', '555', 'Booking', 'HOSTED', 'AcctHosted', null);
        Test.stopTest();

        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resJson);
        System.assertEquals(true, r.get('success'), 'expected success: ' + r.get('errorMessage'));
        System.assertEquals('cs_test_123', r.get('checkoutSessionId'));
        System.assertEquals('https://checkout.stripe.com/c/pay/cs_test_123', r.get('hostedUrl'));
        System.assertEquals('pk_test_123', r.get('publishableKey'));

        Stripe_Payment__c p = [SELECT Status__c, Checkout_Mode__c, Checkout_Session_Id__c, Amount__c
                               FROM Stripe_Payment__c LIMIT 1];
        System.assertEquals('HOSTED', p.Checkout_Mode__c);
        System.assertEquals('cs_test_123', p.Checkout_Session_Id__c);
        System.assertEquals(50, p.Amount__c);
    }

    @isTest static void embedded_returnsClientSecret() {
        StripeTestDataFactory.setupCredentials();
        StripeTestDataFactory.setupConfig('AcctEmb', 'Account', 'EMBEDDED');
        Account a = StripeTestDataFactory.makeAccount();

        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String resJson = StripePaymentEngine.initiatePaymentLWC(
            a.Id, 25, 'usd', 'Jane', 'jane@example.com', null, 'Booking', 'EMBEDDED', 'AcctEmb', null);
        Test.stopTest();

        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resJson);
        System.assertEquals(true, r.get('success'));
        System.assertEquals('cs_test_123_secret', r.get('clientSecret'));
    }

    @isTest static void custom_createsPaymentIntent() {
        StripeTestDataFactory.setupCredentials();
        StripeTestDataFactory.setupConfig('AcctCustom', 'Account', 'CUSTOM');
        Account a = StripeTestDataFactory.makeAccount();

        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String resJson = StripePaymentEngine.initiatePaymentLWC(
            a.Id, 99.99, 'usd', 'Jane', 'jane@example.com', null, 'Booking', 'CUSTOM', 'AcctCustom',
            '{"udf1":"abc","udf2":"def"}');
        Test.stopTest();

        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resJson);
        System.assertEquals(true, r.get('success'));
        System.assertEquals('pi_test_123_secret_abc', r.get('clientSecret'));
        System.assertEquals('pi_test_123', r.get('paymentIntentId'));
        Stripe_Payment__c p = [SELECT Payment_Intent_Id__c, UDF1__c, UDF2__c FROM Stripe_Payment__c LIMIT 1];
        System.assertEquals('pi_test_123', p.Payment_Intent_Id__c);
        System.assertEquals('abc', p.UDF1__c);
    }

    @isTest static void invocable_flowEntry() {
        StripeTestDataFactory.setupCredentials();
        StripeTestDataFactory.setupConfig('AcctFlow', 'Account', 'HOSTED');
        Account a = StripeTestDataFactory.makeAccount();

        StripePaymentEngine.PaymentRequest req = new StripePaymentEngine.PaymentRequest();
        req.recordId = a.Id; req.amount = 10; req.checkoutMode = 'HOSTED'; req.configName = 'AcctFlow';

        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        List<StripePaymentEngine.PaymentResult> results =
            StripePaymentEngine.initiatePayment(new List<StripePaymentEngine.PaymentRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, results.size());
        System.assert(results[0].success);
    }

    @isTest static void noConfig_returnsError() {
        StripeTestDataFactory.setupCredentials();
        Account a = StripeTestDataFactory.makeAccount();
        Test.startTest();
        String resJson = StripePaymentEngine.initiatePaymentLWC(a.Id, 10, 'usd', 'X', 'x@y.com', null, 'P', 'HOSTED', null, null);
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resJson);
        System.assertEquals(false, r.get('success'));
    }

    @isTest static void guest_hardcodedAmount_createsSession() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Payment_Config__c(
            Name = 'GuestBooking', Source_Object__c = 'Lead', Checkout_Mode__c = 'HOSTED',
            Payment_Type__c = 'One-Time', Guest_Enabled__c = true, Currency__c = 'usd',
            Amount_Field__c = 'HARDCODED|49.99|true|true|false|Token|1|true', Is_Active__c = true);

        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String resStr = StripePaymentEngine.createGuestCheckoutSession('GuestBooking', 'Guest', 'g@x.com', '555');
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resStr);
        System.assertEquals(true, r.get('success'), resStr);
        System.assertEquals('cs_test_123', r.get('checkoutSessionId'));
        System.assertEquals('pk_test_123', r.get('publishableKey'));
        System.assert(!resStr.contains('sk_test'), 'Secret key must never be returned to a guest');
        Stripe_Payment__c p = [SELECT Amount__c FROM Stripe_Payment__c LIMIT 1];
        System.assertEquals(49.99, p.Amount__c, 'Amount is resolved server-side from config');
    }

    @isTest static void guest_priceId_createsSession() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Payment_Config__c(
            Name = 'GuestPlan', Source_Object__c = 'Lead', Checkout_Mode__c = 'HOSTED',
            Payment_Type__c = 'Recurring', Guest_Enabled__c = true, Currency__c = 'usd',
            Price_Id__c = 'price_guest_1', Is_Active__c = true);
        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock());
        Test.startTest();
        String resStr = StripePaymentEngine.createGuestCheckoutSession('GuestPlan', 'Guest', 'g@x.com', null);
        Test.stopTest();
        System.assertEquals(true, ((Map<String,Object>) JSON.deserializeUntyped(resStr)).get('success'), resStr);
    }

    @isTest static void guest_notEnabled_rejected() {
        StripeTestDataFactory.setupCredentials();
        insert new Stripe_Payment_Config__c(
            Name = 'NoGuest', Source_Object__c = 'Lead', Checkout_Mode__c = 'HOSTED',
            Guest_Enabled__c = false, Amount_Field__c = 'HARDCODED|10|', Is_Active__c = true);
        Test.startTest();
        String resStr = StripePaymentEngine.createGuestCheckoutSession('NoGuest', 'Guest', 'g@x.com', null);
        Test.stopTest();
        System.assertEquals(false, ((Map<String,Object>) JSON.deserializeUntyped(resStr)).get('success'));
    }

    @isTest static void cardDeclined_writesErrorPayment() {
        StripeTestDataFactory.setupCredentials();
        StripeTestDataFactory.setupConfig('AcctErr', 'Account', 'CUSTOM');
        Account a = StripeTestDataFactory.makeAccount();

        Test.setMock(HttpCalloutMock.class, new StripeCalloutMock(402, true));
        Test.startTest();
        String resJson = StripePaymentEngine.initiatePaymentLWC(a.Id, 10, 'usd', 'X', 'x@y.com', null, 'P', 'CUSTOM', 'AcctErr', null);
        Test.stopTest();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(resJson);
        System.assertEquals(false, r.get('success'));
        Stripe_Payment__c p = [SELECT Status__c FROM Stripe_Payment__c LIMIT 1];
        System.assertEquals('Error', p.Status__c);
    }
}